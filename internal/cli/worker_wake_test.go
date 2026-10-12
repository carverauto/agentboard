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

func TestWorkerWakeResolveCLIExactSourceRead(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENT_ID", "wake-worker")
	const token = "synthetic-wake-receipt-01234567890123456789"
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "token")
	if err := os.WriteFile(tokenFile+".receipt", []byte(token), 0600); err != nil {
		t.Fatal(err)
	}
	callback := map[string]any{
		"attempt_id": "00000000-0000-4000-8000-000000000002", "intent_id": "00000000-0000-4000-8000-000000000001",
		"reason_hash": strings.Repeat("a", 64), "payload_hash": strings.Repeat("b", 64),
		"recipient": map[string]any{"agent_id": "wake-worker", "host_id": "host", "repo": "fixture/repo", "enrollment_revision": int64(1791750000000000), "binding_epoch": 1, "session_id": "session", "adapter_generation": "generation"},
	}
	callbackJSON, _ := json.Marshal(callback)
	// Decode the fixture once so request comparison uses the same JSON number types.
	_ = json.Unmarshal(callbackJSON, &callback)
	source := map[string]any{"kind": "board_message", "id": "42", "version": "2026-10-12T00:00:00.000000Z", "task_id": "source-task"}
	reservation := map[string]any{"protocol_revision": 1, "intent_revision": 1, "effect": "wake.nudge", "reason": "unread_dm", "source": source, "expires_at": "2026-10-12T00:01:00Z", "source_refs": []any{map[string]any{"kind": source["kind"], "id": source["id"], "version": source["version"], "delivery_id": "00000000-0000-4000-8000-000000000003"}}}
	for key, value := range callback {
		reservation[key] = value
	}
	var calls int
	actionable := true
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer "+token || r.Method != http.MethodPost || r.URL.Path != "/api/v1/hosts/host/wake-intents/wake-worker/resolve" {
			t.Errorf("wrong capability or operation: %s %s", r.Method, r.URL.Path)
		}
		var got map[string]any
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Error(err)
		}
		if !reflect.DeepEqual(got, callback) || len(got) != 5 {
			t.Errorf("immutable callback changed: %#v", got)
		}
		response := map[string]any{"protocol_revision": 1, "actionable": actionable, "reservation": reservation, "reason_codes": []string{}, "source": nil}
		if actionable {
			material := map[string]any{"message": map[string]any{"id": 42, "body": "canonical message"}}
			for key, value := range source {
				material[key] = value
			}
			response["source"] = material
		} else {
			response["reason_codes"] = []string{"source_handled"}
		}
		_ = json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()
	cfg := map[string]any{"version": 1, "url": server.URL, "journal_dir": filepath.Join(dir, "journal"), "bindings": []any{map[string]any{
		"agent_id": "wake-worker", "model": "fixture", "harness": "codex", "host_id": "host", "server_id": "server", "session_id": "session", "adapter_generation": "generation", "adapter": "manual", "socket_path": filepath.Join(dir, "absent-socket"), "token_file": tokenFile, "binding_epoch": 1, "repos": []string{"fixture/repo"},
	}}}
	raw, _ := json.Marshal(cfg)
	configPath := filepath.Join(dir, "config.json")
	if err := os.WriteFile(configPath, raw, 0600); err != nil {
		t.Fatal(err)
	}
	inputFile := filepath.Join(dir, "callback.json")
	writeInput := func(raw []byte) {
		t.Helper()
		if err := os.WriteFile(inputFile, raw, 0644); err != nil {
			t.Fatal(err)
		}
	}
	writeInput(callbackJSON)
	run := func(args ...string) (string, error) {
		root := cli.NewRoot()
		var out bytes.Buffer
		root.SetOut(&out)
		root.SetErr(io.Discard)
		base := []string{"worker", "--config", configPath, "--worker-id", "wake-worker", "--session-id", "session", "--adapter-generation", "generation", "--json", "wake-resolve"}
		root.SetArgs(append(base, args...))
		err := root.Execute()
		if strings.Contains(out.String(), token) {
			t.Fatal("receipt capability exposed")
		}
		return out.String(), err
	}
	for i := 0; i < 2; i++ {
		out, err := run("--input-file", inputFile)
		if err != nil || !strings.Contains(out, `"actionable":true`) || !strings.Contains(out, "canonical message") {
			t.Fatalf("source resolution failed: %s %v", out, err)
		}
	}
	actionable = false
	if out, err := run("--input-file", inputFile); err != nil || !strings.Contains(out, `"source":null`) || !strings.Contains(out, "source_handled") {
		t.Fatalf("non-actionable outcome lost: %s %v", out, err)
	}
	if calls != 3 {
		t.Fatalf("implicit received/handled, reconcile, reserve or native operation: %d calls", calls)
	}
	if _, err := os.Stat(filepath.Join(dir, "journal")); !os.IsNotExist(err) {
		t.Fatalf("read changed runtime custody: %v", err)
	}

	badInputs := []string{
		`{}`, `null`, `[]`, string(callbackJSON) + `{}`, strings.Repeat(" ", (16<<10)+1),
		strings.Replace(string(callbackJSON), `"attempt_id":`, `"extra":true,"attempt_id":`, 1),
		strings.Replace(string(callbackJSON), `"attempt_id":`, `"attempt_id":"00000000-0000-4000-8000-000000000099","attempt_id":`, 1),
		strings.Replace(string(callbackJSON), `"attempt_id":`, `"ATTEMPT_ID":`, 1),
		strings.Replace(string(callbackJSON), `"session_id":"session"`, `"session_id":"session","session_id":"session"`, 1),
		strings.Replace(string(callbackJSON), `"session_id":"session"`, `"session_id":"\ud800"`, 1),
		strings.Replace(string(callbackJSON), `"session_id":"session"`, `"session_id":null`, 1),
		strings.Replace(string(callbackJSON), `"binding_epoch":1`, `"binding_epoch":2`, 1),
		strings.Replace(string(callbackJSON), `"host_id":"host"`, `"host_id":"foreign"`, 1),
		strings.Replace(string(callbackJSON), `"repo":"fixture/repo"`, `"repo":"foreign/repo"`, 1),
		strings.Replace(string(callbackJSON), `"reason_hash":"`+strings.Repeat("a", 64)+`"`, `"reason_hash":"bad"`, 1),
	}
	for _, input := range badInputs {
		writeInput([]byte(input))
		if out, err := run("--input-file", inputFile); err == nil || out != "" {
			t.Fatalf("invalid input accepted: %s %v", out, err)
		}
	}
	writeInput(callbackJSON)
	link := filepath.Join(dir, "callback-link.json")
	if err := os.Symlink(inputFile, link); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{nil, {"--input-file", dir}, {"--input-file", link}, {"--input-file", filepath.Join(dir, "missing")}, {"--input-file", inputFile, "--session-id", "replacement"}} {
		if out, err := run(args...); err == nil || out != "" {
			t.Fatalf("unsafe arguments succeeded: %v %s %v", args, out, err)
		}
	}
	if calls != 3 {
		t.Fatalf("invalid callback performed HTTP: %d calls", calls)
	}
	if err := os.Remove(tokenFile + ".receipt"); err != nil {
		t.Fatal(err)
	}
	if out, err := run("--input-file", inputFile); err == nil || out != "" || calls != 3 {
		t.Fatalf("missing receipt capability accepted: %s %v calls=%d", out, err, calls)
	}
}
