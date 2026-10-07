package worker

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math/rand/v2"
	"net/http"
	"net/url"
	"path/filepath"
	"sync"
	"time"

	"github.com/carverauto/agentboard/internal/client"
)

type State struct {
	Worker struct {
		Paused  bool `json:"paused"`
		Enabled bool `json:"enabled"`
	} `json:"worker"`
	Binding *struct {
		Epoch   int64  `json:"binding_epoch"`
		Session string `json:"session_id"`
		Pane    string `json:"pane_id"`
	} `json:"binding"`
	Active *Batch `json:"active_batch"`
}

type Report struct {
	Agent   string `json:"worker_id"`
	State   string `json:"connector_state"`
	Reason  string `json:"reason,omitempty"`
	Attempt string `json:"attempt_id,omitempty"`
}

// CurrentState verifies the canonical epoch and exact native recipient.
func CurrentState(ctx context.Context, a *API, b Binding) (State, error) {
	var s State
	raw, err := a.Call(ctx, http.MethodGet, "state", nil, nil)
	if err != nil {
		return s, err
	}
	if json.Unmarshal(raw, &s) != nil || s.Binding == nil || s.Binding.Epoch != b.Epoch || s.Binding.Session != b.Session || s.Binding.Pane != b.Generation {
		return s, errors.New("binding epoch or session lost; dispatch cancelled")
	}
	return s, nil
}

// Step performs one binding's reconciliation and, only when safe, one submission.
// File custody serializes foreground check-ins with its supervised owner.
func Step(ctx context.Context, cfg Config, b Binding) (Report, error) {
	report := Report{Agent: b.Agent, State: "reconciling"}
	if err := PrivateDir(cfg.JournalDir); err != nil {
		return report, err
	}
	unlock, err := Lock(filepath.Join(cfg.JournalDir, b.Agent+".lock"))
	if err != nil {
		return report, err
	}
	defer unlock()
	a, err := OpenAPI(cfg, b, false)
	if err != nil {
		return report, err
	}
	defer a.Close()
	s, err := CurrentState(ctx, a, b)
	if err != nil {
		return report, err
	}
	if s.Worker.Paused || !s.Worker.Enabled {
		report.State = "paused"
		return report, nil
	}
	j, err := LoadJournal(cfg, b)
	if err != nil {
		return report, err
	}
	if j != nil && j.Phase != "complete" {
		if j.Binding.Epoch != b.Epoch || j.Binding.Generation != b.Generation {
			return report, errors.New("old binding crash journal retained; reconcile old external effects before dispatch")
		}
		return recoverAttempt(ctx, cfg, b, a, j, report)
	}
	if s.Active != nil {
		if err := s.Active.Validate(b); err != nil {
			return report, err
		}
		j = &Journal{Version: Protocol, Key: NewKey(), Phase: "submitting", Batch: s.Active, Binding: b}
		if err := WriteProtected(JournalPath(cfg, b), j); err != nil {
			return report, err
		}
		return recoverAttempt(ctx, cfg, b, a, j, report)
	}
	probe, err := VerifyAdapter(ctx, b)
	if err != nil {
		report.State = "unsupported"
		return report, err
	}
	if probe.State != "idle" && probe.State != "boundary" {
		report.State = "deferred"
		report.Reason = "native boundary not eligible"
		return report, nil
	}
	j = &Journal{Version: Protocol, Key: NewKey(), Phase: "reserving", Binding: b}
	if err := WriteProtected(JournalPath(cfg, b), j); err != nil {
		return report, err
	}
	raw, err := a.Call(ctx, http.MethodPost, "reserve", nil, map[string]any{"idempotency_key": j.Key, "binding_epoch": b.Epoch})
	if err != nil {
		return report, err
	}
	var envelope struct {
		Batch *Batch `json:"batch"`
	}
	if json.Unmarshal(raw, &envelope) != nil {
		return report, errors.New("invalid reservation response")
	}
	if envelope.Batch == nil {
		j.Phase = "complete"
		report.State = "idle"
		return report, WriteProtected(JournalPath(cfg, b), j)
	}
	j.Batch = envelope.Batch
	if err := j.Batch.Validate(b); err != nil {
		return report, err
	}
	j.Phase = "reserved"
	if err := WriteProtected(JournalPath(cfg, b), j); err != nil {
		return report, err
	}
	// Reread desired state immediately before the external call.
	s, err = CurrentState(ctx, a, b)
	if err != nil {
		return report, err
	}
	if s.Worker.Paused || !s.Worker.Enabled {
		j.Outcome = "not_submitted"
		j.Reason = "server pause observed while journal reserved; native call never began"
		return commitResult(ctx, cfg, b, a, j, report)
	}
	return submitAttempt(ctx, cfg, b, a, j, report)
}

// submitAttempt journals the external-I/O boundary before touching the session.
func submitAttempt(ctx context.Context, cfg Config, b Binding, a *API, j *Journal, report Report) (Report, error) {
	j.Phase = "submitting"
	if err := WriteProtected(JournalPath(cfg, b), j); err != nil {
		return report, err
	}
	// Epoch loss/pause cancels in-flight I/O; cancellation never proves non-submission.
	submitCtx, cancel := context.WithCancel(ctx)
	monitorDone := make(chan struct{})
	go func() {
		defer close(monitorDone)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-submitCtx.Done():
				return
			case <-ticker.C:
				check, err := CurrentState(submitCtx, a, b)
				if err != nil || check.Worker.Paused || !check.Worker.Enabled {
					cancel()
					return
				}
			}
		}
	}()
	p, submitErr := AdapterCall(submitCtx, b, "submit", j.Batch)
	cancel()
	<-monitorDone
	j.Outcome = "uncertain"
	j.Reason = "native call begun; acceptance could not be proved; no automatic replay"
	if submitErr == nil && (p.Outcome == "submitted" || p.Outcome == "not_submitted") {
		j.Outcome = p.Outcome
		j.Reason = "matching native session/generation returned explicit " + p.Outcome
	}
	return commitResult(ctx, cfg, b, a, j, report)
}

func commitResult(ctx context.Context, cfg Config, b Binding, a *API, j *Journal, r Report) (Report, error) {
	j.Phase = "result"
	if err := WriteProtected(JournalPath(cfg, b), j); err != nil {
		return r, err
	}
	fences := j.Batch.Fences()
	fences["status"] = j.Outcome
	fences["reason"] = j.Reason
	_, err := a.Call(ctx, http.MethodPost, "attempts/"+url.PathEscape(j.Batch.Attempt)+"/result", nil, fences)
	r.State = j.Outcome
	r.Attempt = j.Batch.Attempt
	if err != nil {
		return r, err
	}
	if j.Outcome == "not_submitted" {
		j.Phase = "complete"
	} else {
		j.Phase = "awaiting_receipt"
	}
	return r, WriteProtected(JournalPath(cfg, b), j)
}

func recoverAttempt(ctx context.Context, cfg Config, b Binding, a *API, j *Journal, r Report) (Report, error) {
	if j.Batch == nil {
		// A reserve request may have committed before losing its response. Retry only
		// its exact idempotency key; this cannot create a second logical attempt.
		raw, err := a.Call(ctx, http.MethodPost, "reserve", nil, map[string]any{"idempotency_key": j.Key, "binding_epoch": b.Epoch})
		if err != nil {
			return r, err
		}
		var e struct {
			Batch *Batch `json:"batch"`
		}
		if json.Unmarshal(raw, &e) != nil {
			return r, errors.New("invalid recovery reservation")
		}
		if e.Batch == nil {
			j.Phase = "complete"
			r.State = "idle"
			return r, WriteProtected(JournalPath(cfg, b), j)
		}
		j.Batch = e.Batch
		j.Phase = "reserved"
	}
	if err := j.Batch.Validate(b); err != nil {
		return r, err
	}
	if j.Phase == "reserved" {
		j.Outcome = "not_submitted"
		j.Reason = "protected fsync journal proves reserved phase; native call never began"
		return commitResult(ctx, cfg, b, a, j, r)
	}
	raw, err := a.Call(ctx, http.MethodPost, "attempts/"+url.PathEscape(j.Batch.Attempt)+"/reconcile", nil, j.Batch.Fences())
	if err != nil {
		return r, err
	}
	var e struct {
		Resolved bool `json:"resolved"`
		Replay   bool `json:"replay_allowed"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return r, errors.New("invalid reconciliation")
	}
	if e.Resolved || e.Replay {
		j.Phase = "complete"
		r.State = "reconciled"
		return r, WriteProtected(JournalPath(cfg, b), j)
	}
	if j.Phase == "result" {
		return commitResult(ctx, cfg, b, a, j, r)
	}
	p, adapterErr := AdapterCall(ctx, b, "reconcile", j.Batch)
	if adapterErr == nil && p.Outcome == "submitted" {
		j.Outcome = "submitted"
		j.Reason = "protected native attempt evidence proves acceptance in exact session/generation"
	} else {
		j.Outcome = "uncertain"
		j.Reason = "native attempt acceptance remains unproven after server/source reconciliation"
	}
	return commitResult(ctx, cfg, b, a, j, r)
}

func delay(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

// Serve multiplexes independently cancellable binding loops without task heartbeats.
func Serve(ctx context.Context, cfg Config, out io.Writer) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	outputErrors := make(chan error, 1)
	var wg sync.WaitGroup
	var output sync.Mutex
	for _, b := range cfg.Bindings {
		wg.Add(1)
		go func(b Binding) {
			defer wg.Done()
			failures := 0
			for ctx.Err() == nil {
				r, err := Step(ctx, cfg, b)
				d := 30 * time.Second
				if err != nil {
					r.State = "degraded"
					r.Reason = err.Error()
					cap := min(60, 1<<min(failures, 6))
					d = time.Duration(cap)*time.Second + time.Duration(rand.IntN(1000))*time.Millisecond
					failures++
					var e *client.Error
					if errors.As(err, &e) && e.RetryAfter > d {
						d = e.RetryAfter
					}
				} else {
					failures = 0
					if ctx.Err() == nil {
						reportHealth(ctx, cfg, b, r)
					}
				}
				output.Lock()
				encodeErr := json.NewEncoder(out).Encode(r)
				output.Unlock()
				if encodeErr != nil {
					select {
					case outputErrors <- errors.New("worker health output unavailable"):
					default:
					}
					cancel()
					return
				}
				if !delay(ctx, d) {
					return
				}
			}
		}(b)
	}
	wg.Wait()
	select {
	case err := <-outputErrors:
		return err
	default:
		return ctx.Err()
	}
}

func reportHealth(ctx context.Context, cfg Config, b Binding, r Report) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	a, err := OpenAPI(cfg, b, false)
	if err != nil {
		return
	}
	defer a.Close()
	adapter := "ready"
	if r.State == "deferred" || r.State == "paused" || r.State == "uncertain" {
		adapter = r.State
	}
	_, _ = a.Call(ctx, http.MethodPost, "state", nil, map[string]any{"binding_epoch": b.Epoch, "connector_state": "healthy", "adapter_state": adapter, "reason": r.State})
}

// Ack is an explicit exact-ID operation. It never acknowledges an entire turn.
func Ack(ctx context.Context, cfg Config, b Binding, kind string, ids []string, key string) (json.RawMessage, error) {
	if kind != "received" && kind != "handled" {
		return nil, errors.New("receipt kind must be received or handled")
	}
	j, err := LoadJournal(cfg, b)
	if err != nil {
		return nil, err
	}
	if j == nil || j.Batch == nil || j.Binding.Epoch != b.Epoch {
		a, err := OpenAPI(cfg, b, true)
		if err != nil {
			return nil, err
		}
		s, stateErr := CurrentState(ctx, a, b)
		a.Close()
		if stateErr != nil {
			return nil, stateErr
		}
		if s.Active == nil {
			return nil, errors.New("no current frozen attempt; a host reservation is required before acknowledging")
		}
		j = &Journal{Batch: s.Active, Binding: b}
	}
	if err := j.Batch.Validate(b); err != nil {
		return nil, err
	}
	members := map[string]bool{}
	for _, id := range j.Batch.IDs {
		members[id] = true
	}
	if len(ids) == 0 || len(ids) > 20 || key == "" {
		return nil, errors.New("exact delivery IDs and an idempotency key are required")
	}
	seen := map[string]bool{}
	for _, id := range ids {
		if !members[id] || seen[id] {
			return nil, errors.New("receipt IDs must be unique members of the frozen attempt")
		}
		seen[id] = true
	}
	a, err := OpenAPI(cfg, b, true)
	if err != nil {
		return nil, err
	}
	defer a.Close()
	// Reconcile canonical source/receipt state before handling an old frame.
	if _, err = a.Call(ctx, http.MethodPost, "attempts/"+url.PathEscape(j.Batch.Attempt)+"/reconcile", nil, j.Batch.Fences()); err != nil {
		return nil, err
	}
	body := j.Batch.Fences()
	body["attempt_id"] = j.Batch.Attempt
	body["kind"] = kind
	body["delivery_ids"] = ids
	body["idempotency_key"] = key
	return a.Call(ctx, http.MethodPost, "receipts", nil, body)
}
