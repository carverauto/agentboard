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
		w.Write([]byte(`{"tasks":[{"id":"ship-it","status":"assigned","priority":0,"held_by_decision":false,"assignee_id":"codex-a","created_at":"2026-10-12T08:00:00Z"},{"id":"old","status":"done","priority":0,"assignee_id":"codex-a","created_at":"2026-10-01T08:00:00Z"}],"next_cursor":null}`))
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

// spawnHost is a host-local allowlist, launcher, source checkout and pool,
// plus a herdr stand-in that records each call and names agentPane's pane.
func spawnHost(t *testing.T, agentPane string) (config, brief, log string) {
	t.Helper()
	dir := t.TempDir()
	launcher, log := filepath.Join(dir, "launch-seat"), filepath.Join(dir, "herdr.log")
	for path, body := range map[string]string{
		launcher: "#!/bin/sh\n",
		filepath.Join(dir, "herdr"): `#!/bin/sh
printf '%s\n' "$*" >> "` + log + `"
case "$1 $2" in
"agent list") printf '%s\n' '{"result":{"agents":[{"pane_id":"w1:p1","name":"` + agentPane + `"}]}}' ;;
"workspace list") printf '%s\n' '{"result":{"workspaces":[]}}' ;;
"workspace create") printf '%s\n' '{"result":{"workspace":{"workspace_id":"w2"}}}' ;;
"tab create") printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2"},"root_pane":{"pane_id":"w2:p2"}}}' ;;
"pane run") printf '%s\n' '{"result":{}}' ;;
*) echo "unexpected herdr $*" >&2; exit 2 ;;
esac
`,
	} {
		if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, sub := range []string{"repo", "pool"} {
		if err := os.Mkdir(filepath.Join(dir, sub), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	config = filepath.Join(dir, "harnesses.json")
	body := `{"version":1,"launcher":"` + launcher + `","repo":"` + filepath.Join(dir, "repo") + `","root":"` + filepath.Join(dir, "pool") +
		`","brief_dir":"` + filepath.Join(dir, "briefs") + `","harnesses":{"codex":{"model":"gpt-5.5","argv":["codex","{brief_text}"]}}}`
	if err := os.WriteFile(config, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_URL", "https://board.example")
	t.Setenv("AGENTBOARD_HERDR_BIN", filepath.Join(dir, "herdr"))
	return config, filepath.Join(dir, "briefs", "codex-b--ship-it.md"), log
}

func runSeatSpawn(config string, extra ...string) (string, error) {
	var out bytes.Buffer
	root := cli.NewRoot()
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(append([]string{"seat", "spawn", "--task", "ship-it", "--agent", "codex-b", "--config", config}, extra...))
	err := root.Execute()
	return out.String(), err
}

func herdrCalls(t *testing.T, log string) []string {
	t.Helper()
	raw, err := os.ReadFile(log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(raw)), "\n")
}

func TestSeatSpawnIsADryRunUnlessApplied(t *testing.T) {
	config, brief, log := spawnHost(t, "codex-a")
	out, err := runSeatSpawn(config, "--harness", "codex")
	if err != nil {
		t.Fatal(err)
	}
	var report struct {
		DryRun  bool              `json:"dry_run"`
		Argv    []string          `json:"argv"`
		Env     map[string]string `json:"env"`
		Spawned *struct {
			Pane string `json:"pane_id"`
		} `json:"spawned"`
	}
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if !report.DryRun || report.Spawned != nil || report.Env["AGENT_ID"] != "codex-b" || report.Env["AGENTBOARD_URL"] != "https://board.example" {
		t.Fatalf("dry run report = %s", out)
	}
	if n := len(report.Argv); n < 3 || report.Argv[n-3] != "--" || report.Argv[n-2] != "codex" || report.Argv[n-1] != "{brief_text}" {
		t.Fatalf("argv = %q", report.Argv)
	}
	if calls := herdrCalls(t, log); len(calls) != 1 || calls[0] != "agent list" {
		t.Fatalf("dry run herdr calls = %q", calls)
	}
	if _, err := os.Stat(brief); !os.IsNotExist(err) {
		t.Fatalf("dry run wrote the brief: %v", err)
	}

	out, err = runSeatSpawn(config, "--harness", "codex", "--apply")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(out), &report); err != nil || report.DryRun || report.Spawned == nil || report.Spawned.Pane != "w2:p2" {
		t.Fatalf("apply report = %s (%v)", out, err)
	}
	calls := herdrCalls(t, log)
	last := calls[len(calls)-1]
	if !strings.HasPrefix(last, "pane run w2:p2 ") || !strings.Contains(last, brief) || !strings.HasSuffix(last, " -- codex '{brief_text}'") {
		t.Fatalf("launch call = %q (all %q)", last, calls)
	}
	if _, err := os.Stat(brief); err != nil {
		t.Fatalf("apply did not write the brief: %v", err)
	}
}

func TestSeatSpawnRefusals(t *testing.T) {
	for name, tc := range map[string]struct {
		pane, want string
		args       []string
		noHerdr    bool
	}{
		"unknown harness":    {pane: "codex-a", args: []string{"--harness", "muse", "--apply"}, want: `harness "muse" is not in the host allowlist`},
		"pane name taken":    {pane: "codex-b", args: []string{"--harness", "codex", "--apply"}, want: "already named codex-b"},
		"herdr unavailable":  {pane: "codex-a", args: []string{"--harness", "codex", "--apply"}, want: "host unavailable", noHerdr: true},
		"apply with dry-run": {pane: "codex-a", args: []string{"--harness", "codex", "--apply", "--dry-run"}, want: "none of the others can be"},
	} {
		t.Run(name, func(t *testing.T) {
			config, _, log := spawnHost(t, tc.pane)
			if tc.noHerdr {
				t.Setenv("AGENTBOARD_HERDR_BIN", filepath.Join(t.TempDir(), "herdr"))
			}
			if _, err := runSeatSpawn(config, tc.args...); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want %q", err, tc.want)
			}
			for _, call := range herdrCalls(t, log) {
				if call != "agent list" {
					t.Fatalf("refused spawn ran herdr %q", call)
				}
			}
		})
	}
	config, _, _ := spawnHost(t, "codex-a")
	if _, err := runSeatSpawn(filepath.Join(filepath.Dir(config), "absent.json"), "--harness", "codex"); err == nil || !strings.Contains(err.Error(), "no harness allowlist") {
		t.Fatalf("missing allowlist err = %v", err)
	}
}
