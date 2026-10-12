package cli_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

func TestWorkerContinuationReadsStateAndRecordsExplicitDisposition(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENT_ID", "idle-worker")
	const token = "synthetic-continuation-receipt-0123456789abcdef"
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "token")
	if err := os.WriteFile(tokenFile+".receipt", []byte(token), 0600); err != nil {
		t.Fatal(err)
	}
	type call struct {
		method string
		body   map[string]any
	}
	var calls []call
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token || r.URL.Path != "/api/v1/workers/idle-worker/continuation" {
			t.Errorf("wrong capability or operation: %s %s", r.Method, r.URL.Path)
		}
		var body map[string]any
		if r.Method == http.MethodPost {
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
		}
		calls = append(calls, call{r.Method, body})
		_ = json.NewEncoder(w).Encode(map[string]any{"protocol_revision": 1, "continuation": map[string]any{"enabled": true, "eligible": false, "reason_codes": []string{"no_new_finding"}}})
	}))
	defer server.Close()
	cfg := map[string]any{"version": 1, "url": server.URL, "journal_dir": filepath.Join(dir, "journal"), "bindings": []any{map[string]any{
		"agent_id": "idle-worker", "model": "fixture", "harness": "codex", "host_id": "host", "server_id": "server", "session_id": "session", "adapter_generation": "generation", "adapter": "manual", "socket_path": filepath.Join(dir, "absent-socket"), "token_file": tokenFile, "binding_epoch": 1, "repos": []string{"fixture/repo"},
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
		root.SetArgs(append([]string{"worker", "--config", configPath, "--worker-id", "idle-worker", "--json", "continuation"}, args...))
		err := root.Execute()
		if strings.Contains(out.String(), token) {
			t.Fatal("receipt capability exposed")
		}
		return out.String(), err
	}

	if out, err := run(); err != nil || !strings.Contains(out, `"no_new_finding"`) {
		t.Fatalf("state read failed: %s %v", out, err)
	}
	if out, err := run("--disposition", "no_new_finding", "--reason", "Turn only reconciled CI; nothing new for peers", "--key", "turn-7"); err != nil || !strings.Contains(out, `"continuation"`) {
		t.Fatalf("disposition failed: %s %v", out, err)
	}
	want := []call{{http.MethodGet, nil}, {http.MethodPost, map[string]any{"disposition": "no_new_finding", "reason": "Turn only reconciled CI; nothing new for peers", "idempotency_key": "turn-7"}}}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("unexpected server operations (receipt, publication or extra fields): %#v", calls)
	}

	// Incomplete or unknown dispositions fail before any server call.
	for _, args := range [][]string{
		{"--disposition", "no_new_finding"},
		{"--disposition", "no_new_finding", "--reason", "x"},
		{"--disposition", "fabricated_finding", "--reason", "x", "--key", "k"},
		{"--reason", "x"},
		{"--key", "k"},
	} {
		if out, err := run(args...); err == nil || out != "" {
			t.Fatalf("invalid arguments accepted: %v %s %v", args, out, err)
		}
	}
	if len(calls) != 2 {
		t.Fatalf("invalid arguments reached the server: %d calls", len(calls))
	}
}
