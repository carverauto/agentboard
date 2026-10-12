package worker_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/worker"
)

// A rebind marks the old in-flight attempt uncertain but keeps it active until
// a captain decides. The host must say so instead of rejecting the batch as
// malformed, and must not adopt, reconcile or replay it from the new epoch.
func TestStepReportsReplacedEpochAttemptNeedsCaptainDecision(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	cfg := workerFixture(t)
	binding := cfg.Bindings[0]
	binding.Epoch = 2
	cfg.Bindings[0] = binding
	payload := `{"deliveries":["delivery-a"]}`
	hash := sha256.Sum256([]byte(payload))
	stale := worker.Batch{
		ID: "batch-old", Attempt: "attempt-old", Agent: binding.Agent, Epoch: 1, Generation: 2,
		Hash: hex.EncodeToString(hash[:]), Payload: payload, IDs: []string{"delivery-a"}, Lease: "2030-01-01T00:00:00Z",
	}
	var otherCalls atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet && r.URL.Path == "/api/v1/workers/"+binding.Agent+"/state" {
			json.NewEncoder(w).Encode(map[string]any{
				"protocol_revision": worker.Protocol, "worker": map[string]any{"enabled": true, "paused": false},
				"binding":      map[string]any{"binding_epoch": binding.Epoch, "session_id": binding.Session, "pane_id": binding.Generation},
				"active_batch": stale,
			})
			return
		}
		otherCalls.Add(1)
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": "invalid_input", "message": "unexpected call"}})
	}))
	defer server.Close()
	cfg.URL = server.URL
	cfg.CAFile = filepath.Join(t.TempDir(), "ca.pem")
	protectedFixture(t, cfg.CAFile, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})))

	_, err := worker.Step(context.Background(), cfg, binding)
	if err == nil || !strings.Contains(err.Error(), "attempt-old") || !strings.Contains(err.Error(), "captain retry decision") || !strings.Contains(err.Error(), "resolve_attempt") {
		t.Fatalf("stale-epoch attempt was not reported as needing a captain decision: %v", err)
	}
	if otherCalls.Load() != 0 {
		t.Fatalf("host made %d calls beyond reading state", otherCalls.Load())
	}
	if _, statErr := os.Stat(worker.JournalPath(cfg, binding)); !os.IsNotExist(statErr) {
		t.Fatalf("host adopted the stale attempt into a journal: %v", statErr)
	}
}
