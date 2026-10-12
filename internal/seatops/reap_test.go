package seatops

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// gitCheckout returns a checkout with one commit. With pushed it has an
// origin remote holding that commit, so the landed gate passes.
func gitCheckout(t *testing.T, pushed bool) string {
	t.Helper()
	base := t.TempDir()
	dir := filepath.Join(base, "work")
	run := func(cwd string, args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = cwd
		cmd.Env = append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	run(dir, "init", "-q", "-b", "main", ".")
	if err := os.WriteFile(filepath.Join(dir, "f"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(dir, "add", "f")
	run(dir, "commit", "-qm", "init")
	if pushed {
		run(base, "init", "-q", "--bare", "remote.git")
		run(dir, "remote", "add", "origin", filepath.Join(base, "remote.git"))
		run(dir, "push", "-q", "origin", "main")
		run(dir, "fetch", "-q", "origin")
	}
	return dir
}

type fakeLeases struct {
	leases   map[string][]Lease
	returned []string
}

func (f *fakeLeases) List(_ context.Context, root string) ([]Lease, error) {
	return f.leases[root], nil
}
func (f *fakeLeases) Return(_ context.Context, l Lease) error {
	f.returned = append(f.returned, l.Path)
	return nil
}

// finishedSeat is codex-a idle in a landed checkout with no work or mail.
func finishedSeat(t *testing.T) (*fakeBoard, *fakeHost) {
	t.Helper()
	board := &fakeBoard{agents: []BoardAgent{seatAgent("codex-a", "codex")}}
	a := pane("w1:p1", "codex-a", "codex", "idle", "sess-1")
	a.Cwd = gitCheckout(t, true)
	return board, &fakeHost{agents: []HostAgent{a}}
}

func reapTwice(t *testing.T, board Board, host Host, leases Leases, cfg Config) ReapReport {
	t.Helper()
	// The first run starts the idle clock; the second is past reap_after.
	if _, err := Reap(context.Background(), board, host, leases, cfg, t0, true); err != nil {
		t.Fatal(err)
	}
	report, err := Reap(context.Background(), board, host, leases, cfg, t0.Add(31*time.Minute), true)
	if err != nil {
		t.Fatal(err)
	}
	return report
}

func TestReapClosesAFinishedSeatAfterTheIdleWindow(t *testing.T) {
	board, host := finishedSeat(t)
	cfg := testConfig(t)
	report, err := Reap(context.Background(), board, host, nil, cfg, t0, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.closed) != 0 {
		t.Fatalf("closed before reap_after elapsed: %v (%+v)", host.closed, report)
	}
	if _, err := Reap(context.Background(), board, host, nil, cfg, t0.Add(31*time.Minute), true); err != nil {
		t.Fatal(err)
	}
	if len(host.closed) != 1 || host.closed[0] != "w1:p1" {
		t.Fatalf("closed = %v", host.closed)
	}
}

func TestReapKeepsSeatsThatAreNotFinished(t *testing.T) {
	cases := map[string]func(*testing.T, *fakeBoard, *fakeHost){
		"owns open task": func(_ *testing.T, b *fakeBoard, _ *fakeHost) {
			b.tasks = map[string][]Task{"codex-a": {{ID: "review-me", Status: "review"}}}
		},
		"unread message": func(_ *testing.T, b *fakeBoard, _ *fakeHost) {
			b.unread = map[string][]Message{"codex-a": {{ID: 1}}}
		},
		"busy":          func(_ *testing.T, _ *fakeBoard, h *fakeHost) { h.agents[0].Status = "working" },
		"unpushed work": func(t *testing.T, _ *fakeBoard, h *fakeHost) { h.agents[0].Cwd = gitCheckout(t, false) },
		"dirty checkout": func(t *testing.T, _ *fakeBoard, h *fakeHost) {
			if err := os.WriteFile(filepath.Join(h.agents[0].Cwd, "f"), []byte("edit"), 0o644); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			board, host := finishedSeat(t)
			setup(t, board, host)
			reapTwice(t, board, host, nil, testConfig(t))
			if len(host.closed) != 0 {
				t.Fatalf("closed an unfinished seat: %v", host.closed)
			}
		})
	}
}

func TestReapDoesNotCloseAPaneThatChangedSinceItWasJudged(t *testing.T) {
	board, host := finishedSeat(t)
	host.afterList = func(a *HostAgent) { a.Session.Value = "sess-new" }
	report := reapTwice(t, board, host, nil, testConfig(t))
	if len(host.closed) != 0 {
		t.Fatalf("closed a changed pane: %v", host.closed)
	}
	if len(report.Actions) == 0 || report.Actions[0].Done || !strings.Contains(report.Actions[0].Reason, "changed") {
		t.Fatalf("actions = %+v", report.Actions)
	}
}

func TestReapKeepsUnknownWorkingDirectory(t *testing.T) {
	board, host := finishedSeat(t)
	host.agents[0].Cwd = ""
	report := reapTwice(t, board, host, nil, testConfig(t))
	if len(host.closed) != 0 {
		t.Fatalf("closed a seat with unknown checkout: %v", host.closed)
	}
	kept := ""
	for _, k := range report.Kept {
		kept += k.Reason + "\n"
	}
	if !strings.Contains(kept, "unknown working directory") {
		t.Fatalf("kept = %+v", report.Kept)
	}
}

func TestReapDoesNotClosePaneThatBecameBusyBeforeClose(t *testing.T) {
	board, host := finishedSeat(t)
	host.readFunc = func(_ string, call int) (string, bool) {
		if call >= 3 {
			return "Working (5s \u2022 esc to interrupt)", true
		}
		return "", true
	}
	report := reapTwice(t, board, host, nil, testConfig(t))
	if len(host.closed) != 0 {
		t.Fatalf("closed a pane that became busy: %v", host.closed)
	}
	if len(report.Actions) == 0 || report.Actions[0].Done || !strings.Contains(report.Actions[0].Reason, "busy") {
		t.Fatalf("actions = %+v", report.Actions)
	}
}

func TestReapHonoursAvailabilityAndKeepsTheLease(t *testing.T) {
	board, host := finishedSeat(t)
	board.agents[0].Availability.State = "paused"
	landed := host.agents[0].Cwd
	leases := &fakeLeases{leases: map[string][]Lease{"/pool": {{Path: landed, Holder: "codex-a"}}}}
	cfg := testConfig(t)
	cfg.TreehouseRoots = []string{"/pool"}
	report := reapTwice(t, board, host, leases, cfg)
	if len(host.closed) != 0 || len(leases.returned) != 0 {
		t.Fatalf("closed = %v returned = %v", host.closed, leases.returned)
	}
	kept := ""
	for _, k := range report.Kept {
		kept += k.Agent + ": " + k.Reason + "\n"
	}
	if !strings.Contains(kept, "codex-a: availability paused") {
		t.Fatalf("kept = %+v", report.Kept)
	}
}

func TestReapKeepsRetiredPausedPane(t *testing.T) {
	cwd := gitCheckout(t, true)
	old := seatAgent("old", "codex")
	old.RetiredAt = &t0
	old.Availability.State = "paused"
	board := &fakeBoard{agents: []BoardAgent{old}}
	a := pane("w1:p1", "old", "codex", "idle", "sess-1")
	a.Cwd = cwd
	host := &fakeHost{agents: []HostAgent{a}}
	report := reapTwice(t, board, host, nil, testConfig(t))
	if len(host.closed) != 0 {
		t.Fatalf("closed a retired paused pane: %v", host.closed)
	}
	kept := ""
	for _, k := range report.Kept {
		kept += k.Agent + ": " + k.Reason + "\n"
	}
	if !strings.Contains(kept, "old: availability paused") {
		t.Fatalf("kept = %+v", report.Kept)
	}
}

func TestReapKeepsRetiredDeniedPane(t *testing.T) {
	cwd := gitCheckout(t, true)
	old := seatAgent("old", "codex")
	old.RetiredAt = &t0
	board := &fakeBoard{agents: []BoardAgent{old}}
	a := pane("w1:p1", "old", "codex", "idle", "sess-1")
	a.Cwd = cwd
	host := &fakeHost{agents: []HostAgent{a}}
	cfg := testConfig(t)
	cfg.Deny = []string{"old"}
	report := reapTwice(t, board, host, nil, cfg)
	if len(host.closed) != 0 {
		t.Fatalf("closed a retired denied pane: %v", host.closed)
	}
	for _, action := range report.Actions {
		if action.Kind == "close_pane" && action.Done {
			t.Fatalf("closed a retired denied pane: %+v", report.Actions)
		}
	}
}

func TestReapDryRunChangesNothing(t *testing.T) {
	board, host := finishedSeat(t)
	cfg := testConfig(t)
	state := State{Seats: map[string]SeatState{"codex-a": {Session: "sess-1", IdleSince: t0.Add(-time.Hour)}}}
	if err := os.MkdirAll(filepath.Dir(cfg.StateFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := state.Save(cfg.StateFile); err != nil {
		t.Fatal(err)
	}
	report, err := Reap(context.Background(), board, host, nil, cfg, t0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.closed) != 0 || len(report.Actions) != 1 || report.Actions[0].Kind != "close_pane" || report.Actions[0].Done {
		t.Fatalf("closed = %v, actions = %+v", host.closed, report.Actions)
	}
}

func TestReapReturnsOnlyAbandonedLandedLeases(t *testing.T) {
	landed, unlanded := gitCheckout(t, true), gitCheckout(t, false)
	live := gitCheckout(t, true)
	board := &fakeBoard{
		agents: []BoardAgent{seatAgent("gone-a", "codex"), seatAgent("live-b", "codex"), seatAgent("gone-c", "codex"), seatAgent("busy-d", "codex"), seatAgent("owner-e", "codex")},
		tasks:  map[string][]Task{"owner-e": {{ID: "still-mine", Status: "in_progress"}}},
	}
	livePane := pane("w2:p1", "live-b", "codex", "working", "s2")
	livePane.Cwd = live
	host := &fakeHost{agents: []HostAgent{livePane}}
	leases := &fakeLeases{leases: map[string][]Lease{"/pool": {
		{Path: landed, Holder: "gone-a"},
		{Path: live, Holder: "live-b"},
		{Path: unlanded, Holder: "gone-c"},
		{Path: landed, Holder: "busy-d", Processes: []any{map[string]any{"pid": 1}}},
		{Path: landed, Holder: "owner-e"},
		{Path: landed, Holder: ""},
	}}}
	cfg := testConfig(t)
	cfg.TreehouseRoots = []string{"/pool"}
	report, err := Reap(context.Background(), board, host, leases, cfg, t0, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(leases.returned) != 1 || leases.returned[0] != landed {
		t.Fatalf("returned = %v\nkept = %+v", leases.returned, report.Kept)
	}
	kept := ""
	for _, k := range report.Kept {
		kept += k.Agent + ": " + k.Reason + "\n"
	}
	for _, want := range []string{"live-b: " + live + ": holder still has a live session", "gone-c: " + unlanded + ": HEAD is not reachable", "busy-d: " + landed + ": processes running", "owner-e: " + landed + ": holder owns open task still-mine", ": " + landed + ": lease has no recorded holder"} {
		if !strings.Contains(kept, want) {
			t.Errorf("kept is missing %q:\n%s", want, kept)
		}
	}
}

func TestReapReportsButNeverReleasesExpiredClaims(t *testing.T) {
	board := &fakeBoard{
		agents: []BoardAgent{seatAgent("stale-a", "codex"), seatAgent("done-b", "codex")},
		tasks:  map[string][]Task{"stale-a": {{ID: "old-claim", Status: "in_progress", ClaimExpired: true}}},
	}
	report, err := Reap(context.Background(), board, &fakeHost{}, nil, testConfig(t), t0, true)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, a := range report.Actions {
		if a.Done {
			t.Fatalf("report-only action was carried out: %+v", a)
		}
		got[a.Kind] = a.Agent + "/" + a.Task
	}
	if got["expired_claim"] != "stale-a/old-claim" || got["retire_candidate"] != "done-b/" {
		t.Fatalf("actions = %+v", report.Actions)
	}
}
