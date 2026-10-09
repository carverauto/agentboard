package cli_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

func TestWorkerMattermostCLIUsesExactScopedOperations(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENT_ID", "worker-inbox")
	const id = "00000000-0000-4000-8000-000000000001"
	version := strings.Repeat("a", 64)
	const token = "synthetic-epoch-receipt-01234567890123456789"
	var actions []string
	var bodies []map[string]any
	stateMode := "current"
	stateCalls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token {
			t.Error("worker CLI did not use epoch receipt capability")
		}
		if r.URL.Path == "/api/v1/workers/worker-inbox/state" {
			stateCalls++
			if r.Method != http.MethodGet {
				t.Error("state preflight must be read-only")
			}
			binding := map[string]any{"binding_epoch": 1, "session_id": "session", "pane_id": "generation"}
			switch stateMode {
			case "epoch":
				binding["binding_epoch"] = 2
			case "session":
				binding["session_id"] = "replacement-session"
			case "generation":
				binding["pane_id"] = "replacement-generation"
			case "missing":
				binding = nil
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"protocol_revision": 1, "worker": map[string]any{"enabled": true, "paused": false}, "binding": binding})
			return
		}
		if r.Method != http.MethodPost {
			t.Error("wrong method")
		}
		actions = append(actions, strings.TrimPrefix(r.URL.Path, "/api/v1/workers/worker-inbox/"))
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		bodies = append(bodies, body)
		io.WriteString(w, `{"protocol_revision":1,"items":[],"handled":[]}`)
	}))
	defer server.Close()
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "token")
	if err := os.WriteFile(tokenFile+".receipt", []byte(token), 0600); err != nil {
		t.Fatal(err)
	}
	cfg := map[string]any{"version": 1, "url": server.URL, "journal_dir": filepath.Join(dir, "journal"), "bindings": []any{map[string]any{
		"agent_id": "worker-inbox", "model": "fixture", "harness": "codex", "host_id": "host", "server_id": "server", "session_id": "session", "adapter_generation": "generation", "adapter": "manual", "socket_path": filepath.Join(dir, "socket"), "token_file": tokenFile, "binding_epoch": 1,
	}}}
	raw, _ := json.Marshal(cfg)
	configPath := filepath.Join(dir, "config.json")
	if err := os.WriteFile(configPath, raw, 0600); err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) (string, error) {
		root := cli.NewRoot()
		var out bytes.Buffer
		root.SetOut(&out)
		root.SetErr(io.Discard)
		base := []string{"worker", "--config", configPath, "--worker-id", "worker-inbox", "--session-id", "session", "--adapter-generation", "generation", "--json"}
		root.SetArgs(append(base, args...))
		err := root.Execute()
		if strings.Contains(out.String(), token) {
			t.Fatal("receipt secret exposed")
		}
		return out.String(), err
	}
	if _, err := run("mattermost-read", "--id", id, "--version", version); err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 || actions[0] != "mattermost_read" || bodies[0]["id"] != id || bodies[0]["version"] != version {
		t.Fatalf("read contract: %v %v", actions, bodies)
	}
	if _, err := run("mattermost-ack", "--item", id+":"+version); err != nil {
		t.Fatal(err)
	}
	if len(actions) != 2 || actions[1] != "mattermost_ack" {
		t.Fatalf("ack contract: %v", actions)
	}
	stateCallsBeforeInvalid := stateCalls
	for _, args := range [][]string{
		{"mattermost-read", "--id", id}, {"mattermost-read", "--id", "../foreign", "--version", version},
		{"mattermost-ack"}, {"mattermost-ack", "--item", id + ":" + version, "--item", id + ":" + version},
		{"mattermost-ack", "--item", id + ":invalid"},
		{"mattermost-read", "--id", id, "--version", version, "--session-id", "foreign"},
	} {
		if out, err := run(args...); err == nil || out != "" {
			t.Fatalf("unsafe args succeeded: %v %s %v", args, out, err)
		}
	}
	if len(actions) != 2 {
		t.Fatalf("invalid input performed HTTP: %v", actions)
	}
	if stateCalls != stateCallsBeforeInvalid {
		t.Fatal("malformed input performed state HTTP")
	}
	// A replacement may have written a fresh receipt file while this command
	// still has the old local config. Pin that token and verify its server
	// epoch/session before reading or handling any source.
	for _, mode := range []string{"epoch", "session", "generation", "missing"} {
		stateMode = mode
		for _, args := range [][]string{{"mattermost-read", "--id", id, "--version", version}, {"mattermost-ack", "--item", id + ":" + version}} {
			if out, err := run(args...); err == nil || out != "" {
				t.Fatalf("stale %s binding performed operation: %v %v", mode, args, err)
			}
		}
	}
	stateMode = "current"
	if len(actions) != 2 {
		t.Fatalf("stale binding reached source operation: %v", actions)
	}
	if err := os.Remove(tokenFile + ".receipt"); err != nil {
		t.Fatal(err)
	}
	if _, err := run("mattermost-read", "--id", id, "--version", version); err == nil {
		t.Fatal("missing receipt capability accepted")
	}
	if len(actions) != 2 {
		t.Fatal("missing capability attempted HTTP")
	}
}
