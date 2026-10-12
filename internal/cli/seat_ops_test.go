package cli_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

// fakeHerdr writes a herdr stand-in that serves one idle pane named codex-a
// and appends every prompt to log.
func fakeHerdr(t *testing.T) (bin, log string) {
	t.Helper()
	dir := t.TempDir()
	bin, log = filepath.Join(dir, "herdr"), filepath.Join(dir, "prompts.log")
	agent := `{"pane_id":"w1:p1","workspace_id":"w1","name":"codex-a","agent":"codex","agent_status":"idle","state_change_seq":3,"agent_session":{"value":"sess-1"}}`
	script := `#!/bin/sh
case "$1 $2" in
"agent list") printf '%s\n' '{"result":{"agents":[` + agent + `]}}' ;;
"agent get") printf '%s\n' '{"result":{"agent":` + agent + `}}' ;;
"agent read") printf 'ready\n' ;;
"agent prompt") printf '%s|%s\n' "$3" "$4" >> "` + log + `" ;;
"agent rename") printf 'rename %s %s\n' "$3" "$4" >> "` + log + `" ;;
*) echo "unexpected herdr $*" >&2; exit 2 ;;
esac
`
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, log
}

func seatOpsBoard(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"api_version":1,"schema_version":41}`))
	})
	mux.HandleFunc("GET /api/v1/agents", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"agents":[{"id":"codex-a","harness":"codex","kind":"seat","routing_eligible":true,"availability":{"state":"active"}}],"next_cursor":null}`))
	})
	mux.HandleFunc("GET /api/v1/tasks", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("owner") != "codex-a" {
			t.Errorf("tasks query = %s", r.URL.RawQuery)
		}
		w.Write([]byte(`{"tasks":[{"id":"ship-it","status":"assigned","priority":0,"assignee_id":"codex-a","created_at":"2026-10-12T08:00:00Z"},{"id":"old","status":"done","priority":0,"assignee_id":"codex-a","created_at":"2026-10-01T08:00:00Z"}],"next_cursor":null}`))
	})
	mux.HandleFunc("GET /api/v1/messages", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("to") != "codex-a" || q.Get("unread") != "true" {
			t.Errorf("messages query = %s", r.URL.RawQuery)
		}
		// Two pages: the nudge must read past the first.
		if q.Get("cursor") == "" {
			w.Write([]byte(`{"messages":[{"id":7,"sender_id":"captain","created_at":"2026-10-12T08:01:00Z","read_at":null}],"next_cursor":"p2"}`))
			return
		}
		w.Write([]byte(`{"messages":[{"id":8,"sender_id":"captain","created_at":"2026-10-12T08:02:00Z","read_at":null}],"next_cursor":null}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func TestSeatNudgeApplyPromptsTheNamedIdlePane(t *testing.T) {
	server := seatOpsBoard(t)
	bin, log := fakeHerdr(t)
	dir := t.TempDir()
	config := filepath.Join(dir, "seat.json")
	body := `{"version":1,"state_file":"` + filepath.Join(dir, "state.json") + `","kill_switch":"` + filepath.Join(dir, "off") + `"}`
	if err := os.WriteFile(config, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_HERDR_BIN", bin)
	t.Setenv("AGENT_ID", "coordinator-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")

	var out bytes.Buffer
	root := cli.NewRoot()
	root.SetOut(&out)
	root.SetArgs([]string{"seat", "nudge", "--apply", "--json", "--config", config})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	var report struct {
		DryRun    bool `json:"dry_run"`
		Decisions []struct {
			Agent, Action, Prompt string
		} `json:"decisions"`
	}
	if err := json.Unmarshal(out.Bytes(), &report); err != nil {
		t.Fatalf("%v: %s", err, out.String())
	}
	if report.DryRun || len(report.Decisions) != 1 || report.Decisions[0].Action != "nudged" {
		t.Fatalf("report = %s", out.String())
	}
	sent, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	line := string(sent)
	for _, want := range []string{"w1:p1|Agentboard nudge", "2 unread message(s)", "ship-it (P0): claim it", "agentboard msg list --unread"} {
		if !strings.Contains(line, want) {
			t.Errorf("prompt %q is missing %q", line, want)
		}
	}
	if strings.Contains(line, "old (P") {
		t.Errorf("done task leaked into the prompt: %q", line)
	}
}

func TestRegisterWithHerdrBackendNamesThePane(t *testing.T) {
	bin, log := fakeHerdr(t)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"api_version":1,"schema_version":41}`))
	})
	mux.HandleFunc("POST /api/v1/agents/register", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"agent":{"id":"codex-a"}}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_HERDR_BIN", bin)
	t.Setenv("HERDR_PANE_ID", "w9:p2")
	t.Setenv("AGENT_ID", "codex-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "codex")
	root := cli.NewRoot()
	root.SetOut(&bytes.Buffer{})
	root.SetArgs([]string{"agent", "register", "--backend", "herdr", "--json"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	sent, err := os.ReadFile(log)
	if err != nil || strings.TrimSpace(string(sent)) != "rename w9:p2 codex-a" {
		t.Fatalf("herdr calls = %q, %v", sent, err)
	}
}
