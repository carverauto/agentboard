package seatops

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// supplyServer is an in-memory seat-supply server for one host.
type supplyServer struct {
	view     HostIntents
	reserved []string
	reports  []LaunchReport
}

func (s *supplyServer) Intents(context.Context) (HostIntents, error) { return s.view, nil }

func (s *supplyServer) Reserve(_ context.Context, id string) (LaunchIntent, error) {
	s.reserved = append(s.reserved, id)
	in := s.find(id)
	if in.State != "pending" {
		return LaunchIntent{}, errors.New("conflict: not pending")
	}
	in.State = "reserved"
	return *in, nil
}

func (s *supplyServer) Report(_ context.Context, id string, r LaunchReport) (LaunchIntent, error) {
	s.reports = append(s.reports, r)
	in := s.find(id)
	in.State, in.Workspace, in.Tab, in.Pane = r.State, r.Workspace, r.Tab, r.Pane
	return *in, nil
}

func (s *supplyServer) find(id string) *LaunchIntent {
	for i := range s.view.Intents {
		if s.view.Intents[i].ID == id {
			return &s.view.Intents[i]
		}
	}
	panic("unknown intent " + id)
}

// supplyHost is a Herdr stand-in that records spawns and lists tabs.
type supplyHost struct {
	fakeHost
	tabs     []HostTab
	spawned  []SpawnRequest
	spawnErr error
}

func (h *supplyHost) Spawn(_ context.Context, req SpawnRequest) (SpawnedSeat, error) {
	h.spawned = append(h.spawned, req)
	if h.spawnErr != nil {
		return SpawnedSeat{}, h.spawnErr
	}
	seat := SpawnedSeat{Workspace: "w1", Tab: "w1:t9", Pane: "w1:p9"}
	h.tabs = append(h.tabs, HostTab{Workspace: seat.Workspace, Tab: seat.Tab, Label: req.Label, Panes: []string{seat.Pane}})
	return seat, nil
}

func (h *supplyHost) SeatTabs(context.Context, string) ([]HostTab, error) { return h.tabs, nil }

type poolLeases struct{ leases []Lease }

func (p poolLeases) List(context.Context, string) ([]Lease, error) { return p.leases, nil }
func (p poolLeases) Return(context.Context, Lease) error           { return nil }

func supplyFixture(t *testing.T, cap int, intents ...LaunchIntent) (*Supplier, *supplyServer, *supplyHost) {
	t.Helper()
	cfg, dir := spawnFixture(t)
	server := &supplyServer{}
	server.view.Enabled, server.view.Host.ID, server.view.Host.LaunchCap = true, "host-a", cap
	server.view.Intents = intents
	host := &supplyHost{}
	s := &Supplier{Server: server, Host: host, Config: cfg, BoardURL: "https://board.example",
		Journal: filepath.Join(dir, "state", "journal.json"),
		Leases:  poolLeases{leases: []Lease{{Path: "/pool/.treehouse/7/repo", Holder: "codex-b"}}}}
	return s, server, host
}

func intent(id, state string) LaunchIntent {
	return LaunchIntent{ID: id, FleetID: "main", SeatID: "seat-b", AgentID: "codex-b", Harness: "codex", State: state}
}

func writeJournal(t *testing.T, path string, entries map[string]journalEntry) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := saveJSON(path, journal{Intents: entries}); err != nil {
		t.Fatal(err)
	}
}

func TestSupplyLaunchesAPendingIntentFromTheAllowlist(t *testing.T) {
	s, server, host := supplyFixture(t, 1, intent("i1", "pending"))
	report, err := s.Tick(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(server.reserved, []string{"i1"}) || len(host.spawned) != 1 {
		t.Fatalf("reserved %v spawned %+v", server.reserved, host.spawned)
	}
	req := host.spawned[0]
	brief := filepath.Join(s.Config.BriefDir, "codex-b--i1.md")
	want := []string{s.Config.Launcher, "--repo", s.Config.Repo, "--root", s.Config.Root, "--brief", brief, "--", "codex", "exec", "{brief}"}
	if req.Label != "codex-b" || !reflect.DeepEqual(req.Argv, want) {
		t.Fatalf("spawn request %+v", req)
	}
	text, err := os.ReadFile(brief)
	if err != nil || !strings.Contains(string(text), "fleet main, seat seat-b") {
		t.Fatalf("brief %q %v", text, err)
	}
	launched := LaunchReport{State: "launched", Workspace: "w1", Tab: "w1:t9", Pane: "w1:p9", Lease: "/pool/.treehouse/7/repo"}
	if !reflect.DeepEqual(server.reports, []LaunchReport{launched}) {
		t.Fatalf("reports %+v (actions %+v)", server.reports, report.Actions)
	}
	j, _ := loadJournal(s.Journal)
	if e := j.Intents["i1"]; e.Step != "spawned" || e.Reported != "launched" || e.Pane != "w1:p9" {
		t.Fatalf("journal %+v", j)
	}
}

func TestSupplyReservesNothingAtCapOrWhenDisabled(t *testing.T) {
	for name, edit := range map[string]func(*supplyServer){
		"cap unset": func(s *supplyServer) { s.view.Host.LaunchCap = 0 },
		"cap held":  func(s *supplyServer) { s.view.Intents = append(s.view.Intents, intent("busy", "uncertain")) },
		"disabled":  func(s *supplyServer) { s.view.Enabled = false },
	} {
		t.Run(name, func(t *testing.T) {
			s, server, host := supplyFixture(t, 1, intent("i1", "pending"))
			edit(server)
			if _, err := s.Tick(context.Background()); err != nil {
				t.Fatal(err)
			}
			if len(server.reserved) != 0 || len(host.spawned) != 0 {
				t.Fatalf("reserved %v spawned %d", server.reserved, len(host.spawned))
			}
		})
	}
}

func TestSupplyFailsUnknownHarnessWithoutLaunching(t *testing.T) {
	in := intent("i1", "pending")
	in.Harness = "muse"
	s, server, host := supplyFixture(t, 1, in)
	if _, err := s.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(host.spawned) != 0 || len(server.reports) != 1 || server.reports[0].State != "failed" || !strings.Contains(server.reports[0].Reason, `"muse" is not in this host's allowlist`) {
		t.Fatalf("spawned %d reports %+v", len(host.spawned), server.reports)
	}
	if j, _ := loadJournal(s.Journal); len(j.Intents) != 0 {
		t.Fatalf("failed intent kept a journal entry: %+v", j)
	}
}

func TestSupplyFailsARefusalBeforeAnyPaneExists(t *testing.T) {
	s, server, host := supplyFixture(t, 1, intent("i1", "pending"))
	host.agents = []HostAgent{{Pane: "w1:p1", Name: "codex-b"}}
	if _, err := s.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(host.spawned) != 0 || len(server.reports) != 1 || server.reports[0].State != "failed" || !strings.Contains(server.reports[0].Reason, "already named codex-b") {
		t.Fatalf("spawned %d reports %+v", len(host.spawned), server.reports)
	}
}

func TestSupplyKeepsAnUnknownLaunchOutcomeUncertain(t *testing.T) {
	s, server, host := supplyFixture(t, 1, intent("i1", "pending"))
	host.spawnErr = errors.New("herdr tab create: timeout")
	if _, err := s.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(server.reports) != 1 || server.reports[0].State != "uncertain" {
		t.Fatalf("reports %+v", server.reports)
	}
	// The next pass finds no pane: the intent stays uncertain, nothing relaunches.
	if _, err := s.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(host.spawned) != 1 || len(server.reports) != 1 || len(server.reserved) != 1 {
		t.Fatalf("spawned %d reports %+v reserved %v", len(host.spawned), server.reports, server.reserved)
	}
}

func TestSupplyRestartReconciliation(t *testing.T) {
	t.Run("pane opened before the report", func(t *testing.T) {
		s, server, host := supplyFixture(t, 1, intent("i1", "reserved"))
		writeJournal(t, s.Journal, map[string]journalEntry{"i1": {Agent: "codex-b", Step: "spawning"}})
		host.tabs = []HostTab{{Workspace: "w1", Tab: "w1:t4", Label: "codex-b", Panes: []string{"w1:p4"}}}
		if _, err := s.Tick(context.Background()); err != nil {
			t.Fatal(err)
		}
		if len(host.spawned) != 0 || len(server.reports) != 1 || server.reports[0].State != "launched" || server.reports[0].Pane != "w1:p4" {
			t.Fatalf("spawned %d reports %+v", len(host.spawned), server.reports)
		}
	})
	t.Run("pane creation never started", func(t *testing.T) {
		s, server, host := supplyFixture(t, 1, intent("i1", "reserved"))
		writeJournal(t, s.Journal, map[string]journalEntry{"i1": {Agent: "codex-b", Step: "reserving"}})
		if _, err := s.Tick(context.Background()); err != nil {
			t.Fatal(err)
		}
		// The same intent launches again; nothing new is reserved.
		if len(host.spawned) != 1 || len(server.reserved) != 0 {
			t.Fatalf("spawned %d reserved %v", len(host.spawned), server.reserved)
		}
		if server.reports[0].State != "launched" || server.find("i1").State != "launched" {
			t.Fatalf("reports %+v", server.reports)
		}
	})
	t.Run("pane missing after creation started", func(t *testing.T) {
		s, server, host := supplyFixture(t, 1, intent("i1", "reserved"))
		writeJournal(t, s.Journal, map[string]journalEntry{"i1": {Agent: "codex-b", Step: "spawning"}})
		if _, err := s.Tick(context.Background()); err != nil {
			t.Fatal(err)
		}
		if len(host.spawned) != 0 || len(server.reports) != 1 || server.reports[0].State != "uncertain" {
			t.Fatalf("spawned %d reports %+v", len(host.spawned), server.reports)
		}
	})
	t.Run("no journal entry", func(t *testing.T) {
		s, server, host := supplyFixture(t, 1, intent("i1", "reserved"))
		if _, err := s.Tick(context.Background()); err != nil {
			t.Fatal(err)
		}
		if len(host.spawned) != 0 || len(server.reports) != 1 || !strings.Contains(server.reports[0].Reason, "no journal entry") {
			t.Fatalf("spawned %d reports %+v", len(host.spawned), server.reports)
		}
	})
}

func TestSupplyClosesALaunchedIntentOnlyWhenItsPaneIsGone(t *testing.T) {
	in := intent("i1", "launched")
	in.Pane = "w1:p4"
	s, server, host := supplyFixture(t, 0, in)
	host.tabs = []HostTab{{Workspace: "w1", Tab: "w1:t4", Label: "codex-b", Panes: []string{"w1:p4"}}}
	if _, err := s.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(server.reports) != 0 {
		t.Fatalf("live pane reported %+v", server.reports)
	}
	host.tabs = nil
	if _, err := s.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(server.reports) != 1 || server.reports[0].State != "closed" {
		t.Fatalf("reports %+v", server.reports)
	}
}

func TestSupplyReportsUncertainUntilTheLeaseAppears(t *testing.T) {
	s, server, _ := supplyFixture(t, 1, intent("i1", "pending"))
	s.Leases = poolLeases{}
	if _, err := s.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(server.reports) != 1 || server.reports[0].State != "uncertain" || server.reports[0].Pane != "w1:p9" {
		t.Fatalf("reports %+v", server.reports)
	}
	s.Leases = poolLeases{leases: []Lease{{Path: "/pool/.treehouse/7/repo", Holder: "codex-b"}}}
	if _, err := s.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(server.reports) != 2 || server.reports[1].State != "launched" || server.reports[1].Lease != "/pool/.treehouse/7/repo" {
		t.Fatalf("reports %+v", server.reports)
	}
}

func TestSupplyReportJSONOmitsUnsetFields(t *testing.T) {
	raw, _ := json.Marshal(LaunchReport{State: "failed", Reason: "no harness"})
	if string(raw) != `{"state":"failed","reason":"no harness"}` {
		t.Fatalf("report JSON %s", raw)
	}
}
