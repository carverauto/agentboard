package seatops

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC)

type fakeHost struct {
	agents  []HostAgent
	tails   map[string]string
	prompts []string // "pane: text"
	closed  []string
	// afterList mutates an agent between list and the pre-send recheck.
	afterList  func(*HostAgent)
	promptErr  error
	listCalled int
	readCalls  int
	readFunc   func(pane string, call int) (string, bool)
}

func (h *fakeHost) Agents(context.Context) ([]HostAgent, error) {
	h.listCalled++
	return append([]HostAgent(nil), h.agents...), nil
}

func (h *fakeHost) Agent(_ context.Context, pane string) (HostAgent, error) {
	for _, a := range h.agents {
		if a.Pane == pane {
			if h.afterList != nil {
				h.afterList(&a)
			}
			return a, nil
		}
	}
	return HostAgent{}, errors.New("no such pane")
}

func (h *fakeHost) Read(_ context.Context, pane string, _ int) (string, error) {
	h.readCalls++
	if h.readFunc != nil {
		if s, ok := h.readFunc(pane, h.readCalls); ok {
			return s, nil
		}
	}
	return h.tails[pane], nil
}

func (h *fakeHost) Prompt(_ context.Context, pane, text string) error {
	if h.promptErr != nil {
		return h.promptErr
	}
	h.prompts = append(h.prompts, pane+": "+text)
	return nil
}

func (h *fakeHost) ClosePane(_ context.Context, pane string) error {
	h.closed = append(h.closed, pane)
	return nil
}

type fakeBoard struct {
	agents []BoardAgent
	tasks  map[string][]Task
	unread map[string][]Message
	bodies map[string]string
	at     map[string]time.Time
}

func (b *fakeBoard) Agents(context.Context) ([]BoardAgent, error) { return b.agents, nil }
func (b *fakeBoard) OwnedTasks(_ context.Context, id string) ([]Task, error) {
	return b.tasks[id], nil
}
func (b *fakeBoard) Unread(_ context.Context, id string) ([]Message, error) {
	return b.unread[id], nil
}
func (b *fakeBoard) LastBody(_ context.Context, id string) (string, time.Time, error) {
	return b.bodies[id], b.at[id], nil
}

func seatAgent(id, harness string) BoardAgent {
	a := BoardAgent{ID: id, Harness: harness, Kind: "seat", RoutingEligible: true}
	a.Availability.State = "active"
	return a
}

func pane(id, name, kind, status, session string) HostAgent {
	a := HostAgent{Pane: id, Workspace: strings.Split(id, ":")[0], Name: name, Kind: kind, Status: status, StateChangeSeq: 7}
	a.Session.Value = session
	return a
}

func testConfig(t *testing.T) Config {
	t.Helper()
	dir := t.TempDir()
	return Config{Version: 1, MinGap: Duration{15 * time.Minute}, IdleAfter: Duration{20 * time.Minute}, ReapAfter: Duration{30 * time.Minute},
		StateFile: filepath.Join(dir, "state.json"), KillSwitch: filepath.Join(dir, "off")}
}

func p(n int) *int { return &n }

// oneIdleSeat is codex-a idle in w1:p1 with one unread message.
func oneIdleSeat() (*fakeBoard, *fakeHost) {
	board := &fakeBoard{
		agents: []BoardAgent{seatAgent("codex-a", "codex")},
		unread: map[string][]Message{"codex-a": {{ID: 41, CreatedAt: t0.Add(-time.Minute)}}},
	}
	host := &fakeHost{agents: []HostAgent{pane("w1:p1", "codex-a", "codex", "idle", "sess-1")}}
	return board, host
}

func TestNudgePromptsIdleSeatOnceForTheSameReasons(t *testing.T) {
	cfg := testConfig(t)
	board, host := oneIdleSeat()
	report, err := Nudge(context.Background(), board, host, cfg, t0, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 || !strings.HasPrefix(host.prompts[0], "w1:p1: Agentboard nudge") || !strings.Contains(host.prompts[0], "1 unread message") {
		t.Fatalf("prompts = %q, report = %+v", host.prompts, report)
	}
	if _, err := Nudge(context.Background(), board, host, cfg, t0.Add(time.Hour), true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 {
		t.Fatalf("same reason set was nudged again: %q", host.prompts)
	}
	board.unread["codex-a"] = append(board.unread["codex-a"], Message{ID: 42, CreatedAt: t0.Add(30 * time.Minute)})
	if _, err := Nudge(context.Background(), board, host, cfg, t0.Add(time.Hour), true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 2 {
		t.Fatalf("a new message should nudge again after the gap: %q", host.prompts)
	}
}

func TestNudgeRateLimitsANewReasonInsideTheGap(t *testing.T) {
	cfg := testConfig(t)
	board, host := oneIdleSeat()
	if _, err := Nudge(context.Background(), board, host, cfg, t0, true); err != nil {
		t.Fatal(err)
	}
	board.unread["codex-a"] = append(board.unread["codex-a"], Message{ID: 42, CreatedAt: t0})
	report, err := Nudge(context.Background(), board, host, cfg, t0.Add(5*time.Minute), true)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 || report.Decisions[0].Reason != "rate limit" {
		t.Fatalf("prompts = %q, decision = %+v", host.prompts, report.Decisions[0])
	}
}

func TestNudgeDryRunSendsNothingAndKeepsNoState(t *testing.T) {
	cfg := testConfig(t)
	board, host := oneIdleSeat()
	report, err := Nudge(context.Background(), board, host, cfg, t0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 0 || report.Decisions[0].Action != "nudge" || report.Decisions[0].Prompt == "" {
		t.Fatalf("prompts = %q, decision = %+v", host.prompts, report.Decisions[0])
	}
	if _, err := os.Stat(cfg.StateFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("dry run wrote state: %v", err)
	}
}

func TestNudgeLeavesBusySeatsAlone(t *testing.T) {
	for name, setup := range map[string]func(*fakeHost){
		"herdr working":          func(h *fakeHost) { h.agents[0].Status = "working" },
		"idle status, busy text": func(h *fakeHost) { h.tails = map[string]string{"w1:p1": "• Working (12s • esc to interrupt)"} },
		"unknown status":         func(h *fakeHost) { h.agents[0].Status = "unknown" },
		"approval prompt open":   func(h *fakeHost) { h.agents[0].Status = "blocked" },
	} {
		t.Run(name, func(t *testing.T) {
			board, host := oneIdleSeat()
			setup(host)
			if _, err := Nudge(context.Background(), board, host, testConfig(t), t0, true); err != nil {
				t.Fatal(err)
			}
			if len(host.prompts) != 0 {
				t.Fatalf("busy seat was prompted: %q", host.prompts)
			}
		})
	}
}

func TestNudgeAbortsWhenTheRecipientChangesBeforeSend(t *testing.T) {
	for name, change := range map[string]func(*HostAgent){
		"new native session": func(a *HostAgent) { a.Session.Value = "sess-2" },
		"state changed":      func(a *HostAgent) { a.StateChangeSeq++ },
		"renamed pane":       func(a *HostAgent) { a.Name = "codex-b" },
		"different harness":  func(a *HostAgent) { a.Kind = "claude" },
	} {
		t.Run(name, func(t *testing.T) {
			board, host := oneIdleSeat()
			host.afterList = change
			report, err := Nudge(context.Background(), board, host, testConfig(t), t0, true)
			if err != nil {
				t.Fatal(err)
			}
			if len(host.prompts) != 0 || report.Decisions[0].Action != "abort" {
				t.Fatalf("prompts = %q, decision = %+v", host.prompts, report.Decisions[0])
			}
		})
	}
}

func TestNudgeDoesNotReplayAnUncertainSend(t *testing.T) {
	cfg := testConfig(t)
	board, host := oneIdleSeat()
	host.promptErr = errors.New("socket closed mid-request")
	report, err := Nudge(context.Background(), board, host, cfg, t0, true)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(report.Decisions[0].Reason, "uncertain") {
		t.Fatalf("decision = %+v", report.Decisions[0])
	}
	host.promptErr = nil
	if _, err := Nudge(context.Background(), board, host, cfg, t0.Add(time.Hour), true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 0 {
		t.Fatalf("uncertain send was replayed: %q", host.prompts)
	}
}

func TestNudgeRetriesAfterTheHostRejectedBeforeSending(t *testing.T) {
	cfg := testConfig(t)
	board, host := oneIdleSeat()
	host.promptErr = ErrAgentBlocked
	if _, err := Nudge(context.Background(), board, host, cfg, t0, true); err != nil {
		t.Fatal(err)
	}
	host.promptErr = nil
	if _, err := Nudge(context.Background(), board, host, cfg, t0.Add(time.Minute), true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 {
		t.Fatalf("a rejected-before-send nudge should be retried: %q", host.prompts)
	}
}

func TestNudgeOnlyTellsWaitingSeatsAboutNewMessages(t *testing.T) {
	cfg := testConfig(t)
	waitStart := t0.Add(-2 * time.Hour)
	board := &fakeBoard{
		agents: []BoardAgent{seatAgent("codex-a", "codex")},
		tasks: map[string][]Task{"codex-a": {
			{ID: "needs-answer", Status: "blocked", Priority: p(0)},
			{ID: "other-work", Status: "assigned", Priority: p(1)},
		}},
		unread: map[string][]Message{"codex-a": {{ID: 10, CreatedAt: waitStart.Add(-time.Hour)}}},
		bodies: map[string]string{"needs-answer": "Blocked: waiting on captain decision about schema"},
		at:     map[string]time.Time{"needs-answer": waitStart},
	}
	host := &fakeHost{agents: []HostAgent{pane("w1:p1", "codex-a", "codex", "idle", "sess-1")}}
	report, err := Nudge(context.Background(), board, host, cfg, t0, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 0 || report.Decisions[0].State != "waiting" {
		t.Fatalf("waiting seat with only an old message was prompted: %q %+v", host.prompts, report.Decisions[0])
	}
	board.unread["codex-a"] = append(board.unread["codex-a"], Message{ID: 11, CreatedAt: t0.Add(-time.Minute)})
	if _, err := Nudge(context.Background(), board, host, cfg, t0.Add(time.Minute), true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 || !strings.Contains(host.prompts[0], "New message(s) 11") || strings.Contains(host.prompts[0], "claim it") {
		t.Fatalf("prompts = %q", host.prompts)
	}
}

func TestNudgePointsIdleSeatAtItsHighestPriorityTask(t *testing.T) {
	board := &fakeBoard{
		agents: []BoardAgent{seatAgent("codex-a", "codex")},
		tasks: map[string][]Task{"codex-a": {
			{ID: "low", Status: "assigned", Priority: p(3), CreatedAt: t0.Add(-48 * time.Hour)},
			{ID: "urgent", Status: "assigned", Priority: p(0), CreatedAt: t0.Add(-time.Hour)},
		}},
	}
	host := &fakeHost{agents: []HostAgent{pane("w1:p1", "codex-a", "codex", "idle", "sess-1")}}
	if _, err := Nudge(context.Background(), board, host, testConfig(t), t0, true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 || !strings.Contains(host.prompts[0], "urgent (P0): claim it") {
		t.Fatalf("prompts = %q", host.prompts)
	}
}

func TestNudgeKeepsGoingOnlyAfterIdleThreshold(t *testing.T) {
	cfg := testConfig(t)
	board := &fakeBoard{
		agents: []BoardAgent{seatAgent("codex-a", "codex")},
		tasks:  map[string][]Task{"codex-a": {{ID: "mine", Status: "in_progress", Priority: p(1), ClaimedAt: &t0}}},
	}
	host := &fakeHost{agents: []HostAgent{pane("w1:p1", "codex-a", "codex", "idle", "sess-1")}}
	if _, err := Nudge(context.Background(), board, host, cfg, t0, true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 0 {
		t.Fatalf("freshly idle seat was prompted: %q", host.prompts)
	}
	if _, err := Nudge(context.Background(), board, host, cfg, t0.Add(25*time.Minute), true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 || !strings.Contains(host.prompts[0], "idle 25m with open work; continue mine") {
		t.Fatalf("prompts = %q", host.prompts)
	}
}

func TestNudgeSkipsUnavailableDeniedAndKillSwitched(t *testing.T) {
	t.Run("availability paused", func(t *testing.T) {
		board, host := oneIdleSeat()
		board.agents[0].Availability.State = "paused"
		if _, err := Nudge(context.Background(), board, host, testConfig(t), t0, true); err != nil {
			t.Fatal(err)
		}
		if len(host.prompts) != 0 {
			t.Fatal("paused seat was prompted")
		}
	})
	t.Run("denied workspace", func(t *testing.T) {
		board, host := oneIdleSeat()
		cfg := testConfig(t)
		cfg.Deny = []string{"w1"}
		if _, err := Nudge(context.Background(), board, host, cfg, t0, true); err != nil {
			t.Fatal(err)
		}
		if len(host.prompts) != 0 {
			t.Fatal("denied seat was prompted")
		}
	})
	t.Run("kill switch", func(t *testing.T) {
		board, host := oneIdleSeat()
		cfg := testConfig(t)
		if err := os.WriteFile(cfg.KillSwitch, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := Nudge(context.Background(), board, host, cfg, t0, true); err != nil {
			t.Fatal(err)
		}
		if host.listCalled != 0 || len(host.prompts) != 0 {
			t.Fatal("kill switch did not stop the run")
		}
	})
}

func TestNudgeSkipsOverlappingRuns(t *testing.T) {
	cfg := testConfig(t)
	lock, err := AcquireLock(cfg.StateFile)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Release()
	board, host := oneIdleSeat()
	if _, err := Nudge(context.Background(), board, host, cfg, t0, true); !errors.Is(err, ErrLocked) {
		t.Fatalf("err = %v, want ErrLocked", err)
	}
}

func TestDiscoverSeatsRequiresOneMatchingNamedPane(t *testing.T) {
	retired := seatAgent("old", "codex")
	retired.RetiredAt = &t0
	agents := []BoardAgent{seatAgent("codex-a", "codex"), seatAgent("claude-b", "claude"), seatAgent("codex-c", "codex"), retired}
	panes := []HostAgent{
		pane("w1:p1", "codex-a", "codex", "idle", "s1"),
		pane("w2:p1", "claude-b", "codex", "idle", "s2"), // wrong harness in the pane
		pane("w3:p1", "codex-c", "codex", "idle", "s3"),
		pane("w4:p1", "codex-c", "codex", "idle", "s4"), // duplicate name
		pane("w5:p1", "old", "codex", "idle", "s5"),
		pane("w6:p1", "", "codex", "idle", "s6"), // unnamed: not a seat
		pane("w7:p1", "stranger", "codex", "idle", "s7"),
	}
	seats, skipped := DiscoverSeats(panes, agents, Config{})
	if len(seats) != 1 || seats[0].Agent.ID != "codex-a" {
		t.Fatalf("seats = %+v", seats)
	}
	reasons := map[string]string{}
	for _, s := range skipped {
		reasons[s.Agent] = s.Reason
	}
	want := map[string]string{"claude-b": `pane runs "codex"`, "codex-c": "2 panes", "old": "retired", "stranger": "not a board agent"}
	for agent, fragment := range want {
		if !strings.Contains(reasons[agent], fragment) {
			t.Errorf("%s skipped for %q, want %q", agent, reasons[agent], fragment)
		}
	}
}

func TestPickCard(t *testing.T) {
	claimedAt := t0
	cases := []struct {
		name  string
		owned []Task
		wait  map[string]time.Time
		want  string
	}{
		{"parked P0 outranks assigned P3", []Task{{ID: "p3", Status: "assigned", Priority: p(3)}, {ID: "p0", Status: "blocked", Priority: p(0)}}, nil, "p0"},
		{"actionable beats parked at same priority", []Task{{ID: "parked", Status: "blocked", Priority: p(1), CreatedAt: t0.Add(-time.Hour)}, {ID: "ready", Status: "assigned", Priority: p(1), CreatedAt: t0}}, nil, "ready"},
		{"claimed P1 beats older unclaimed P1", []Task{{ID: "older", Status: "assigned", Priority: p(1), CreatedAt: t0.Add(-time.Hour)}, {ID: "mine", Status: "in_progress", Priority: p(1), CreatedAt: t0, ClaimedAt: &claimedAt}}, nil, "mine"},
		{"oldest wins below P1", []Task{{ID: "newer", Status: "assigned", Priority: p(2), CreatedAt: t0}, {ID: "older", Status: "assigned", Priority: p(2), CreatedAt: t0.Add(-time.Hour)}}, nil, "older"},
		{"held by a decision is never picked", []Task{{ID: "held", Status: "assigned", Priority: p(0), HeldByDecision: true}, {ID: "free", Status: "assigned", Priority: p(3)}}, nil, "free"},
		{"waiting on captain is never picked", []Task{{ID: "waits", Status: "blocked", Priority: p(0)}, {ID: "next", Status: "assigned", Priority: p(2)}}, map[string]time.Time{"waits": t0}, "next"},
		{"review is not work to pick", []Task{{ID: "rev", Status: "review", Priority: p(0)}}, nil, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, _ := PickCard(c.owned, c.wait)
			id := ""
			if got != nil {
				id = got.ID
			}
			if id != c.want {
				t.Fatalf("picked %q, want %q", id, c.want)
			}
		})
	}
}

func TestNudgeGenericQuestionLineStillSurfacesAssignedWork(t *testing.T) {
	board := &fakeBoard{
		agents: []BoardAgent{seatAgent("codex-a", "codex")},
		tasks:  map[string][]Task{"codex-a": {{ID: "urgent", Status: "assigned", Priority: p(0), CreatedAt: t0.Add(-time.Hour)}}},
	}
	host := &fakeHost{
		agents: []HostAgent{pane("w1:p1", "codex-a", "codex", "idle", "sess-1")},
		tails:  map[string]string{"w1:p1": "Continue with the next step in the plan?"},
	}
	report, err := Nudge(context.Background(), board, host, testConfig(t), t0, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 || !strings.Contains(host.prompts[0], "urgent (P0): claim it") {
		t.Fatalf("prompts = %q, decision = %+v", host.prompts, report.Decisions[0])
	}
	if report.Decisions[0].Mode != "work" {
		t.Fatalf("mode = %q, want work", report.Decisions[0].Mode)
	}
}

func TestNudgeQuestionWithoutWaitingTasksUsesNeutralAnswerPrompt(t *testing.T) {
	view := SeatView{
		Agent:   seatAgent("codex-a", "codex"),
		Host:    pane("w1:p1", "codex-a", "codex", "idle", "sess-1"),
		Tail:    "Shall I proceed with the migration?",
		Unread:  []Message{{ID: 7, CreatedAt: t0.Add(-time.Minute)}},
		Waiting: map[string]time.Time{},
	}
	d := Decide(view, t0, Config{})
	if d.State != "waiting" || d.Mode != "answer" {
		t.Fatalf("decision = %+v", d)
	}
	if strings.Contains(d.Prompt, "waiting on the captain") || strings.Contains(d.Prompt, "stay parked") {
		t.Fatalf("answer prompt claims captain wait: %q", d.Prompt)
	}
	if !strings.Contains(d.Prompt, "you asked a question") || !strings.Contains(d.Prompt, "7") {
		t.Fatalf("neutral prompt = %q", d.Prompt)
	}
}

func TestLoadConfigDefaultsAndRejectsWritableFile(t *testing.T) {
	dir := t.TempDir()
	cfg, err := LoadConfig(filepath.Join(dir, "missing.json"))
	if err != nil || cfg.MinGap.Duration != 15*time.Minute || cfg.ReapAfter.Duration != 30*time.Minute {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte(`{"version":1,"min_gap":"5m","deny":["w9"]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if cfg, err = LoadConfig(path); err != nil || cfg.MinGap.Duration != 5*time.Minute || cfg.Deny[0] != "w9" {
		t.Fatalf("loaded = %+v, %v", cfg, err)
	}
	if err := os.Chmod(path, 0o666); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "writable") {
		t.Fatalf("world-writable config accepted: %v", err)
	}
	if err := os.WriteFile(path, []byte(`{"version":1,"seats":["x"]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil {
		t.Fatal("unknown config field accepted")
	}
}
