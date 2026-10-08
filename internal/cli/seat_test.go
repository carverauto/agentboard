package cli_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

type seatBoard struct {
	status string
	bodies []string
	server *httptest.Server
}

func newSeatBoard(t *testing.T, status string, bodies ...string) *seatBoard {
	t.Helper()
	f := &seatBoard{status: status, bodies: bodies}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"api_version":1,"schema_version":22}`))
	})
	mux.HandleFunc("GET /api/v1/tasks/seat-task", func(w http.ResponseWriter, r *http.Request) {
		events := []any{}
		for i, body := range bodies {
			events = append(events, map[string]any{"id": i + 1, "body": body})
		}
		w.WriteHeader(200)
		json.NewEncoder(w).Encode(map[string]any{
			"task":   map[string]any{"id": "seat-task", "status": f.status},
			"events": events,
		})
	})
	f.server = httptest.NewServer(mux)
	t.Cleanup(f.server.Close)
	return f
}

func seatEnv(t *testing.T, f *seatBoard) {
	t.Helper()
	t.Setenv("AGENTBOARD_URL", f.server.URL)
	t.Setenv("AGENT_ID", "worker-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	t.Setenv("AGENTBOARD_TREEHOUSE_BIN", "")
}

func runSeatCommand(t *testing.T, args ...string) error {
	t.Helper()
	root := cli.NewRoot()
	root.SetArgs(args)
	return root.Execute()
}

func TestSeatReturnRefusesNonTerminalTask(t *testing.T) {
	f := newSeatBoard(t, "in_progress", "agentboard-seat worktree=/s treehouse_version=3.1.2 treehouse_root=/r lease_holder=worker-a")
	seatEnv(t, f)
	err := runSeatCommand(t, "seat", "return", "seat-task")
	if err == nil || !strings.Contains(err.Error(), "not done/cancelled") {
		t.Fatalf("expected not-done refusal, got %v", err)
	}
}

func TestSeatReturnRefusesWithoutSlotRecord(t *testing.T) {
	f := newSeatBoard(t, "done", "some other progress note")
	seatEnv(t, f)
	err := runSeatCommand(t, "seat", "return", "seat-task")
	if err == nil || !strings.Contains(err.Error(), "no complete slot record") {
		t.Fatalf("expected slot-record refusal, got %v", err)
	}
}

func TestSeatReturnRefusesForeignHolder(t *testing.T) {
	f := newSeatBoard(t, "done", "agentboard-seat worktree=/s treehouse_version=3.1.2 treehouse_root=/r lease_holder=someone-else")
	seatEnv(t, f)
	err := runSeatCommand(t, "seat", "return", "seat-task")
	if err == nil || !strings.Contains(err.Error(), "lease holder") {
		t.Fatalf("expected holder refusal, got %v", err)
	}
}

func seatScratchRepo(t *testing.T, dirty, commitSide bool) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main", ".")
	if err := os.WriteFile(filepath.Join(dir, "f"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", "f")
	run("commit", "-qm", "init")
	if commitSide {
		run("checkout", "-qb", "side")
		if err := os.WriteFile(filepath.Join(dir, "g"), []byte("y"), 0o644); err != nil {
			t.Fatal(err)
		}
		run("add", "g")
		run("commit", "-qm", "side")
	}
	if dirty {
		if err := os.WriteFile(filepath.Join(dir, "f"), []byte("dirty"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestSeatReturnRefusesUnlandedSlot(t *testing.T) {
	dir := seatScratchRepo(t, false, true)
	body := "agentboard-seat worktree=" + dir + " treehouse_version=3.1.2 treehouse_root=/r lease_holder=worker-a"
	f := newSeatBoard(t, "done", body)
	seatEnv(t, f)
	err := runSeatCommand(t, "seat", "return", "seat-task")
	if err == nil || !strings.Contains(err.Error(), "landed gate") {
		t.Fatalf("expected landed-gate refusal, got %v", err)
	}
}

func TestSeatReturnRefusesUnknownBinaryVersion(t *testing.T) {
	dir := seatScratchRepo(t, false, false)
	body := "agentboard-seat worktree=" + dir + " treehouse_version=9.9.9 treehouse_root=/r lease_holder=worker-a"
	f := newSeatBoard(t, "cancelled", body)
	seatEnv(t, f)
	err := runSeatCommand(t, "seat", "return", "seat-task")
	if err == nil || !strings.Contains(err.Error(), "no Treehouse v9.9.9 binary") {
		t.Fatalf("expected binary refusal, got %v", err)
	}
}
