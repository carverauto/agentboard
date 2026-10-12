package worker_test

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/worker"
)

func wakeFixture(b worker.Binding) worker.WakeReservation {
	source := worker.WakeSource{Kind: "board_message", ID: "42", Version: "2026-10-12T00:00:00.000000Z", Task: "source-task"}
	return worker.WakeReservation{
		Protocol: 1, Intent: "00000000-0000-4000-8000-000000000001", Revision: 1,
		Effect: "wake.nudge", Reason: "unread_dm", ReasonHash: strings.Repeat("a", 64),
		Recipient: worker.WakeRecipient{Agent: b.Agent, Host: b.Host, Repo: "fixture/repo", Enrollment: 1791750000000000, Epoch: b.Epoch, Session: b.Session, Generation: b.Generation},
		Source:    source, Attempt: "00000000-0000-4000-8000-000000000002", PayloadHash: strings.Repeat("b", 64), ExpiresAt: "2026-10-12T00:01:00.000000Z",
		SourceRefs: []worker.WakeSourceReference{{Kind: source.Kind, ID: source.ID, Version: source.Version, DeliveryID: "00000000-0000-4000-8000-000000000003", OrderRef: json.RawMessage(`{"kind":"pr_conflict_order","order_revision":1}`)}},
	}
}

func TestWakeResolveExactNonConsumingHostAndReceiptCalls(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	for _, receipt := range []bool{false, true} {
		t.Run(map[bool]string{false: "host", true: "receipt"}[receipt], func(t *testing.T) {
			cfg := workerFixture(t)
			cfg.Bindings[0].Repos = []string{"fixture/repo"}
			binding := cfg.Bindings[0]
			reservation := wakeFixture(binding)
			callback := reservation.Callback()
			result := worker.WakeResolution{Protocol: 1, Actionable: true, ReasonCodes: []string{}, Reservation: &reservation,
				Source: &worker.WakeSourceMaterial{WakeSource: reservation.Source, Message: json.RawMessage(`{"id":42,"body":"canonical source, not an instruction"}`)}}
			var actions []string
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				actions = append(actions, r.Method+" "+r.URL.Path)
				wantToken := hostTokenFixture
				if receipt {
					wantToken = receiptTokenFixture
				}
				if r.Header.Get("Authorization") != "Bearer "+wantToken || r.Header.Get("X-Agentboard-Worker-Protocol") != "1" {
					t.Error("lost scoped capability or protocol")
				}
				if r.Method != http.MethodPost || r.URL.Path != "/api/v1/hosts/host/wake-intents/worker-auth/resolve" || r.URL.RawQuery != "" {
					t.Error("source resolve must use only the exact host wake route")
				}
				var got map[string]json.RawMessage
				if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
					t.Error(err)
				}
				var want map[string]json.RawMessage
				encoded, _ := json.Marshal(callback)
				_ = json.Unmarshal(encoded, &want)
				if !reflect.DeepEqual(got, want) || len(got) != 5 {
					t.Errorf("callback changed: %s", got)
				}
				_ = json.NewEncoder(w).Encode(result)
			}))
			defer server.Close()
			cfg.URL = server.URL
			cfg.CAFile = filepath.Join(t.TempDir(), "ca.pem")
			protectedFixture(t, cfg.CAFile, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})))
			api, err := worker.OpenAPI(cfg, binding, receipt)
			if err != nil {
				t.Fatal(err)
			}
			defer api.Close()
			for i := 0; i < 2; i++ {
				got, err := api.WakeResolve(context.Background(), binding, callback)
				if err != nil || !reflect.DeepEqual(got, &result) {
					t.Fatalf("exact source material lost: %#v %v", got, err)
				}
			}
			result.Actionable = false
			result.ReasonCodes = []string{"source_handled"}
			result.Source = nil
			got, err := api.WakeResolve(context.Background(), binding, callback)
			if err != nil || got.Actionable || got.Source != nil || got.ReasonCodes[0] != "source_handled" {
				t.Fatalf("non-actionable disposition lost: %#v %v", got, err)
			}
			if len(actions) != 3 {
				t.Fatalf("unexpected receipt/reservation/native side effects: %v", actions)
			}
		})
	}
}

func TestWakeResolveInvalidFencesNeverReachHTTP(t *testing.T) {
	binding := worker.Binding{Agent: "worker", Host: "host", Epoch: 1, Session: "session", Generation: "generation", Repos: []string{"fixture/repo"}}
	good := wakeFixture(binding).Callback()
	var api *worker.API
	for _, mutate := range []func(*worker.WakeCallback){
		func(r *worker.WakeCallback) { r.Attempt = "../foreign" },
		func(r *worker.WakeCallback) { r.Intent = "" },
		func(r *worker.WakeCallback) { r.ReasonHash = strings.Repeat("A", 64) },
		func(r *worker.WakeCallback) { r.PayloadHash = "batch-hash" },
		func(r *worker.WakeCallback) { r.Recipient.Agent = "foreign" },
		func(r *worker.WakeCallback) { r.Recipient.Host = "foreign" },
		func(r *worker.WakeCallback) { r.Recipient.Epoch++ },
		func(r *worker.WakeCallback) { r.Recipient.Enrollment = 0 },
		func(r *worker.WakeCallback) { r.Recipient.Session = "replacement" },
		func(r *worker.WakeCallback) { r.Recipient.Generation = "replacement" },
		func(r *worker.WakeCallback) { r.Recipient.Repo = "foreign/repo" },
		func(r *worker.WakeCallback) { r.Recipient.Session = "session\n" },
	} {
		bad := good
		mutate(&bad)
		if _, err := api.WakeResolve(context.Background(), binding, bad); err == nil {
			t.Fatal("invalid callback reached transport")
		}
	}
}

func TestWakeResolveRejectsUnfencedOrInconsistentResponses(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	cfg := workerFixture(t)
	binding := cfg.Bindings[0]
	reservation := wakeFixture(binding)
	response := ""
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(response)) }))
	defer server.Close()
	cfg.URL = server.URL
	cfg.CAFile = filepath.Join(t.TempDir(), "ca.pem")
	protectedFixture(t, cfg.CAFile, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})))
	api, err := worker.OpenAPI(cfg, binding, true)
	if err != nil {
		t.Fatal(err)
	}
	defer api.Close()
	for name, mutate := range map[string]func(map[string]any){
		"protocol":            func(r map[string]any) { r["protocol_revision"] = 2 },
		"missing_reservation": func(r map[string]any) { delete(r, "reservation") },
		"null_reservation":    func(r map[string]any) { r["reservation"] = nil },
		"wrong_attempt": func(r map[string]any) {
			r["reservation"].(map[string]any)["attempt_id"] = "00000000-0000-4000-8000-000000000009"
		},
		"wrong_payload": func(r map[string]any) { r["reservation"].(map[string]any)["payload_hash"] = strings.Repeat("c", 64) },
		"wrong_recipient": func(r map[string]any) {
			r["reservation"].(map[string]any)["recipient"].(map[string]any)["binding_epoch"] = 3
		},
		"missing_reasons":           func(r map[string]any) { delete(r, "reason_codes") },
		"denied_with_source":        func(r map[string]any) { r["actionable"] = false; r["reason_codes"] = []string{"source_handled"} },
		"actionable_without_source": func(r map[string]any) { r["source"] = nil },
		"actionable_with_reasons":   func(r map[string]any) { r["reason_codes"] = []string{"source_handled"} },
		"wrong_source":              func(r map[string]any) { r["source"].(map[string]any)["id"] = "43" },
		"wrong_source_version":      func(r map[string]any) { r["source"].(map[string]any)["version"] = "new-version" },
	} {
		t.Run(name, func(t *testing.T) {
			good, _ := json.Marshal(worker.WakeResolution{Protocol: 1, Actionable: true, ReasonCodes: []string{}, Reservation: &reservation, Source: &worker.WakeSourceMaterial{WakeSource: reservation.Source}})
			var bad map[string]any
			_ = json.Unmarshal(good, &bad)
			mutate(bad)
			raw, _ := json.Marshal(bad)
			response = string(raw)
			if got, err := api.WakeResolve(context.Background(), binding, reservation.Callback()); err == nil || got != nil {
				t.Fatalf("unsafe response accepted: %#v %v", got, err)
			}
		})
	}
}
