package worker_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/worker"
)

// The real Step reaches a protected Unix adapter and HTTP boundary. Server-side
// source identity/currentness is owned by the packaged conflict-source fixture.
func TestStepConflictDispatchBeforeNativeIO(t *testing.T) {
	for _, mode := range []string{"deny", "missing", "allow"} {
		t.Run(mode, func(t *testing.T) {
			t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
			cfg := workerFixture(t)
			if err := os.Chmod(filepath.Dir(cfg.Bindings[0].TokenFile), 0700); err != nil {
				t.Fatal(err)
			}
			binding := cfg.Bindings[0]
			binding.Adapter = worker.AdapterVersion
			cfg.Bindings[0] = binding
			if err := worker.PrivateDir(cfg.JournalDir); err != nil {
				t.Fatal(err)
			}
			// Keep the socket under the private fixture root and within Unix path limits.
			binding.Socket = filepath.Join(filepath.Dir(binding.TokenFile), "adapter.sock")
			cfg.Bindings[0] = binding
			listener, err := net.Listen("unix", binding.Socket)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { listener.Close() })
			if err := os.Chmod(binding.Socket, 0600); err != nil {
				t.Fatal(err)
			}
			var nativeCalls, dispatchCalls, resultCalls atomic.Int32
			go func() {
				for {
					conn, err := listener.Accept()
					if err != nil {
						return
					}
					var request struct{ Action string }
					if err := json.NewDecoder(conn).Decode(&request); err != nil {
						conn.Close()
						continue
					}
					probe := worker.Probe{Protocol: worker.Protocol, Version: binding.Adapter,
						Session: binding.Session, Generation: binding.Generation, State: "idle",
						Capabilities: map[string]worker.Capability{}}
					for _, name := range []string{"idle_wake", "turn_start", "tool_return", "receipt", "recovery"} {
						probe.Capabilities[name] = worker.Capability{Supported: true, Reason: "Invented protected adapter"}
					}
					if request.Action == "submit" {
						nativeCalls.Add(1)
						probe.Outcome = "submitted"
					}
					json.NewEncoder(conn).Encode(probe)
					conn.Close()
				}
			}()
			payload := `{"items":[{"order_ref":{"kind":"pr_conflict_order","order_id":"11111111-1111-4111-8111-111111111111","order_revision":1,"repair_task_id":"fixture-repair","pull_request_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","default_ref":"main","default_tip_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","evaluation_base_ref":"main","evaluation_base_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","recipient_id":"worker-auth"}}]}`
			digest := sha256.Sum256([]byte(payload))
			batch := worker.Batch{ID: "batch", Attempt: "attempt", Agent: binding.Agent, Epoch: binding.Epoch,
				Generation: 1, Payload: payload, Hash: hex.EncodeToString(digest[:]), IDs: []string{"delivery"}, Lease: "2030-01-01T00:00:00Z"}
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				switch {
				case strings.HasSuffix(r.URL.Path, "/state"):
					json.NewEncoder(w).Encode(map[string]any{"protocol_revision": 1, "worker": map[string]any{"enabled": true, "paused": false},
						"binding": map[string]any{"binding_epoch": binding.Epoch, "session_id": binding.Session, "pane_id": binding.Generation}})
				case strings.HasSuffix(r.URL.Path, "/reserve"):
					json.NewEncoder(w).Encode(map[string]any{"protocol_revision": 1, "batch": batch})
				case strings.HasSuffix(r.URL.Path, "/dispatch"):
					dispatchCalls.Add(1)
					var fences map[string]any
					json.NewDecoder(r.Body).Decode(&fences)
					if fences["payload_hash"] != batch.Hash || fences["binding_epoch"] != float64(binding.Epoch) ||
						fences["dispatch_generation"] != float64(batch.Generation) {
						t.Error("dispatch lost frozen fences")
					}
					response := map[string]any{"protocol_revision": 1, "reason_codes": []string{"source_stale_order"}}
					if mode != "missing" {
						response["dispatch_allowed"] = mode == "allow"
					}
					json.NewEncoder(w).Encode(response)
				case strings.HasSuffix(r.URL.Path, "/result"):
					resultCalls.Add(1)
					var body map[string]any
					json.NewDecoder(r.Body).Decode(&body)
					want := "not_submitted"
					if mode == "allow" {
						want = "submitted"
					}
					if body["status"] != want {
						t.Errorf("transport outcome: got %v want %s", body["status"], want)
					}
					json.NewEncoder(w).Encode(map[string]any{"protocol_revision": 1})
				default:
					t.Errorf("unexpected worker operation %s", r.URL.Path)
					http.Error(w, "unexpected", 500)
				}
			}))
			t.Cleanup(server.Close)
			cfg.URL = server.URL
			cfg.CAFile = filepath.Join(filepath.Dir(binding.TokenFile), "ca.pem")
			protectedFixture(t, cfg.CAFile, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})))
			_, err = worker.Step(context.Background(), cfg, binding)
			if err != nil {
				t.Fatal(err)
			}
			want := int32(0)
			if mode == "allow" {
				want = 1
			}
			if nativeCalls.Load() != want || dispatchCalls.Load() != 1 || resultCalls.Load() != 1 {
				t.Fatalf("native=%d dispatch=%d result=%d; wanted native=%d and one dispatch/result", nativeCalls.Load(), dispatchCalls.Load(), resultCalls.Load(), want)
			}
		})
	}
}
