package worker_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/worker"
)

func TestStepHistoricalReconciliation(t *testing.T) {
	tests := []struct {
		name     string
		phase    string
		change   func(map[string]any, map[string]any)
		complete bool
	}{
		{name: "not_submitted", complete: true},
		{name: "resolved", complete: true, change: func(e, b map[string]any) {
			e["resolved"], b["status"] = true, "submitted"
		}},
		{name: "legacy_replay_evidence", complete: true, change: func(e, b map[string]any) {
			e["replay_allowed"] = true
			delete(b, "status")
		}},
		{name: "uncertain", change: func(e, b map[string]any) { b["status"] = "uncertain" }},
		{name: "submitting_uncertain", phase: "submitting", change: func(e, b map[string]any) { b["status"] = "uncertain" }},
		{name: "result_uncertain", phase: "result", change: func(e, b map[string]any) { b["status"] = "uncertain" }},
		{name: "submitted_without_resolution", change: func(e, b map[string]any) { b["status"] = "submitted" }},
		{name: "missing_status", change: func(e, b map[string]any) { delete(b, "status") }},
		{name: "noncanonical_status", change: func(e, b map[string]any) { b["status"] = "NOT_SUBMITTED" }},
		{name: "malformed_status", change: func(e, b map[string]any) { b["status"] = true }},
		{name: "missing_batch", change: func(e, b map[string]any) { delete(e, "batch") }},
		{name: "resolved_missing_batch", change: func(e, b map[string]any) {
			e["resolved"] = true
			delete(e, "batch")
		}},
		{name: "replay_missing_batch", change: func(e, b map[string]any) {
			e["replay_allowed"] = true
			delete(e, "batch")
		}},
		{name: "null_batch", change: func(e, b map[string]any) { e["batch"] = nil }},
		{name: "malformed_batch", change: func(e, b map[string]any) { e["batch"] = "not a batch" }},
		{name: "different_worker", change: func(e, b map[string]any) { b["worker_id"] = "other-worker" }},
		{name: "different_epoch", change: func(e, b map[string]any) { b["binding_epoch"] = 99 }},
		{name: "different_attempt", change: func(e, b map[string]any) { b["attempt_id"] = "different-attempt" }},
		{name: "different_batch", change: func(e, b map[string]any) { b["batch_id"] = "different-batch" }},
		{name: "different_hash", change: func(e, b map[string]any) { b["payload_hash"] = "different-hash" }},
		{name: "different_generation", change: func(e, b map[string]any) { b["dispatch_generation"] = 2 }},
		{name: "resolved_different_generation", change: func(e, b map[string]any) {
			e["resolved"], b["dispatch_generation"] = true, 2
		}},
		{name: "replay_different_generation", change: func(e, b map[string]any) {
			e["replay_allowed"], b["dispatch_generation"] = true, 2
		}},
		{name: "different_payload", change: func(e, b map[string]any) {
			payload := `{"deliveries":["different-delivery"]}`
			hash := sha256.Sum256([]byte(payload))
			b["payload"], b["payload_hash"] = payload, hex.EncodeToString(hash[:])
		}},
		{name: "different_membership", change: func(e, b map[string]any) { b["delivery_ids"] = []string{"other-delivery"} }},
		{name: "reordered_membership", change: func(e, b map[string]any) { b["delivery_ids"] = []string{"delivery-b", "delivery-a"} }},
		{name: "empty_membership", change: func(e, b map[string]any) { b["delivery_ids"] = []string{} }},
	}
	for _, rebound := range []bool{false, true} {
		bindingName := "same_epoch"
		if rebound {
			bindingName = "rebound"
		}
		for _, tt := range tests {
			t.Run(bindingName+"/"+tt.name, func(t *testing.T) {
				t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
				cfg := workerFixture(t)
				originalBinding := cfg.Bindings[0]
				binding := originalBinding
				if rebound {
					binding.Epoch++
					binding.Session = "replacement-session"
					binding.Generation = "replacement-generation"
				}
				cfg.Bindings[0] = binding
				payload := `{"deliveries":["delivery-a","delivery-b"]}`
				hash := sha256.Sum256([]byte(payload))
				batch := worker.Batch{
					ID: "batch-original", Attempt: "attempt-original", Agent: originalBinding.Agent,
					Epoch: originalBinding.Epoch, Generation: 1, Hash: hex.EncodeToString(hash[:]),
					Payload: payload, IDs: []string{"delivery-a", "delivery-b"}, Lease: "2030-01-01T00:00:00Z",
				}
				phase := tt.phase
				if phase == "" {
					phase = "awaiting_receipt"
				}
				journal := worker.Journal{
					Version: worker.Protocol, Key: "original-reservation-key", Phase: phase,
					Batch: &batch, Binding: originalBinding, Outcome: "uncertain", Reason: "original unresolved native evidence",
				}
				path := worker.JournalPath(cfg, binding)
				if err := worker.WriteProtected(path, journal); err != nil {
					t.Fatal(err)
				}
				before, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				frozen, err := json.Marshal(batch)
				if err != nil {
					t.Fatal(err)
				}
				var returned map[string]any
				if err := json.Unmarshal(frozen, &returned); err != nil {
					t.Fatal(err)
				}
				returned["status"] = "not_submitted"
				envelope := map[string]any{
					"protocol_revision": worker.Protocol, "historical": true,
					"resolved": false, "replay_allowed": false, "batch": returned,
				}
				if tt.change != nil {
					tt.change(envelope, returned)
				}
				var stateCalls, reconcileCalls, forbiddenCalls atomic.Int32
				server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if r.Header.Get("Authorization") != "Bearer "+hostTokenFixture || r.Header.Get("X-Agentboard-Worker-Protocol") != "1" {
						t.Error("historical recovery lost its host capability or protocol")
					}
					prefix := "/api/v1/workers/" + binding.Agent + "/"
					w.Header().Set("Content-Type", "application/json")
					switch {
					case r.Method == http.MethodGet && r.URL.Path == prefix+"state":
						stateCalls.Add(1)
						// A newer active attempt must not replace the retained journal.
						active := batch
						active.ID, active.Attempt, active.Epoch, active.Generation = "batch-current", "attempt-current", binding.Epoch, 2
						json.NewEncoder(w).Encode(map[string]any{
							"protocol_revision": worker.Protocol, "worker": map[string]any{"enabled": true, "paused": false},
							"binding":      map[string]any{"binding_epoch": binding.Epoch, "session_id": binding.Session, "pane_id": binding.Generation},
							"active_batch": active,
						})
					case r.Method == http.MethodPost && r.URL.Path == prefix+"attempts/"+batch.Attempt+"/reconcile":
						reconcileCalls.Add(1)
						var got map[string]any
						if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
							t.Error(err)
						}
						want := map[string]any{"binding_epoch": float64(batch.Epoch), "dispatch_generation": float64(batch.Generation), "payload_hash": batch.Hash}
						if !reflect.DeepEqual(got, want) {
							t.Errorf("historical reconcile changed original fences: got %v, want %v", got, want)
						}
						json.NewEncoder(w).Encode(envelope)
					default:
						forbiddenCalls.Add(1)
						t.Errorf("historical recovery attempted forbidden fresh I/O: %s %s", r.Method, r.URL.Path)
						w.WriteHeader(http.StatusBadRequest)
						json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": "invalid_input", "message": "unexpected mutation"}})
					}
				}))
				defer server.Close()
				cfg.URL = server.URL
				cfg.CAFile = filepath.Join(t.TempDir(), "ca.pem")
				protectedFixture(t, cfg.CAFile, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})))
				// The manual adapter and nonexistent socket cannot inject a native prompt.
				// Calling Step once also prevents a later poll from reserving new work.
				report, stepErr := worker.Step(context.Background(), cfg, binding)
				if stateCalls.Load() != 1 || reconcileCalls.Load() != 1 || forbiddenCalls.Load() != 0 {
					t.Errorf("unexpected API calls: state=%d reconcile=%d forbidden=%d", stateCalls.Load(), reconcileCalls.Load(), forbiddenCalls.Load())
				}
				after, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				if !tt.complete {
					if stepErr == nil || report.State == "reconciled" {
						t.Errorf("unproven historical attempt was not blocked: report=%+v err=%v", report, stepErr)
					}
					if !bytes.Equal(before, after) {
						t.Error("blocked historical recovery changed immutable journal evidence")
					}
					return
				}
				if stepErr != nil || report.State != "reconciled" || report.Attempt != batch.Attempt {
					t.Errorf("historical positive evidence did not retire exact attempt: report=%+v err=%v", report, stepErr)
				}
				got, err := worker.LoadJournal(cfg, binding)
				if err != nil {
					t.Fatal(err)
				}
				journal.Phase = "complete"
				if !reflect.DeepEqual(got, &journal) {
					t.Errorf("retirement changed original evidence beyond phase: got %+v, want %+v", got, &journal)
				}
			})
		}
	}
}
