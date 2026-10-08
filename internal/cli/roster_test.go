package cli_test

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

type rosterBoard struct {
	beats  atomic.Int32
	retire []byte
}

func newRosterBoard(t *testing.T) (string, *rosterBoard) {
	t.Helper()
	f := &rosterBoard{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"api_version":1,"schema_version":22}`))
	})
	mux.HandleFunc("POST /api/v1/agents/worker-a/retire", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		f.retire = body
		w.Write([]byte(`{"agent":{"id":"worker-a"}}`))
	})
	mux.HandleFunc("POST /api/v1/agents/worker-a/restore", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"agent":{"id":"worker-a"}}`))
	})
	mux.HandleFunc("POST /api/v1/agents/worker-a/heartbeat", func(w http.ResponseWriter, r *http.Request) {
		if f.beats.Add(1) > 1 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Write([]byte(`{"agent":{"id":"worker-a"}}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	token := filepath.Join(t.TempDir(), "captain.token")
	if err := os.WriteFile(token, []byte("test-captain-token-0123456789abcdef"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", token)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENT_ID", "worker-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	return server.URL, f
}

func runRosterCommand(args ...string) error {
	root := cli.NewRoot()
	root.SetArgs(args)
	return root.Execute()
}

func TestAgentRetireRequiresReason(t *testing.T) {
	newRosterBoard(t)
	err := runRosterCommand("agent", "retire", "worker-a")
	if err == nil || !strings.Contains(err.Error(), "--reason is required") {
		t.Fatalf("expected reason error, got %v", err)
	}
}

func TestAgentRetirePostsReasonAndForce(t *testing.T) {
	_, f := newRosterBoard(t)
	if err := runRosterCommand("agent", "retire", "worker-a", "--reason", "fixture cleanup", "--force"); err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(f.retire, &body); err != nil {
		t.Fatal(err)
	}
	if body["reason"] != "fixture cleanup" || body["force"] != true {
		t.Fatalf("unexpected retire body %s", f.retire)
	}
}

func TestAgentRestorePosts(t *testing.T) {
	newRosterBoard(t)
	if err := runRosterCommand("agent", "restore", "worker-a"); err != nil {
		t.Fatal(err)
	}
}

func TestHeartbeatEveryRejectsNegative(t *testing.T) {
	newRosterBoard(t)
	err := runRosterCommand("agent", "heartbeat", "--status", "busy", "--every", "-1s")
	if err == nil || !strings.Contains(err.Error(), "--every must be a positive duration") {
		t.Fatalf("expected duration error, got %v", err)
	}
}

func TestHeartbeatEveryTicksUntilError(t *testing.T) {
	_, f := newRosterBoard(t)
	// Second beat fails on the stub, which stops the ticker loop.
	err := runRosterCommand("agent", "heartbeat", "--status", "busy", "--every", "1ms")
	if err == nil {
		t.Fatal("expected ticker loop to surface the failing beat")
	}
	if f.beats.Load() != 2 {
		t.Fatalf("expected immediate beat plus one tick, got %d", f.beats.Load())
	}
}
