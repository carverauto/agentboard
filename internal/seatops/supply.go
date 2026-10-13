package seatops

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// LaunchIntent is one server seat-launch intent as its host sees it. It names
// a loadout seat, its identity and harness; what runs comes only from the
// host-local allowlist.
type LaunchIntent struct {
	ID        string `json:"id"`
	FleetID   string `json:"fleet_id"`
	SeatID    string `json:"seat_id"`
	AgentID   string `json:"agent_id"`
	Harness   string `json:"harness"`
	State     string `json:"state"`
	Workspace string `json:"workspace_id"`
	Tab       string `json:"tab_id"`
	Pane      string `json:"pane_id"`
}

// HostIntents is the server's view for one enrolled host: its launch cap and
// every live intent it may reserve or already holds.
type HostIntents struct {
	Enabled bool `json:"seat_supply_enabled"`
	Host    struct {
		ID        string `json:"host_id"`
		LaunchCap int    `json:"launch_cap"`
	} `json:"host"`
	Intents []LaunchIntent `json:"intents"`
}

// LaunchReport is a host's report on one intent: launched (pane and lease),
// uncertain or failed (reason), or closed once a launched pane is gone.
type LaunchReport struct {
	State     string `json:"state"`
	Reason    string `json:"reason,omitempty"`
	Workspace string `json:"workspace_id,omitempty"`
	Tab       string `json:"tab_id,omitempty"`
	Pane      string `json:"pane_id,omitempty"`
	Lease     string `json:"lease_path,omitempty"`
}

// SupplyServer is the server side of seat supply for one enrolled host.
type SupplyServer interface {
	Intents(ctx context.Context) (HostIntents, error)
	Reserve(ctx context.Context, id string) (LaunchIntent, error)
	Report(ctx context.Context, id string, report LaunchReport) (LaunchIntent, error)
}

// Supplier launches one host's live launch intents. The server decides which
// seats are wanted; the supplier only reserves intents for its own host, opens
// a Herdr tab running launch-seat from the allowlist and reports the outcome.
type Supplier struct {
	Server   SupplyServer
	Host     Host
	Leases   Leases
	Config   SpawnConfig
	BoardURL string
	// Journal records each launch step; its lock serializes daemons.
	Journal string
	// LeaseWait bounds how long a new launch waits for its Treehouse lease
	// before it reports uncertain; later passes keep looking.
	LeaseWait time.Duration
	// Poll is the lease lookup interval while waiting (default 2s).
	Poll time.Duration
}

// SupplyAction is one thing a pass did or kept for an intent.
type SupplyAction struct {
	Intent string `json:"intent"`
	Agent  string `json:"agent"`
	Action string `json:"action"`
	Reason string `json:"reason,omitempty"`
}

// SupplyReport is the bounded JSON summary of one pass.
type SupplyReport struct {
	Enabled   bool           `json:"seat_supply_enabled"`
	LaunchCap int            `json:"launch_cap"`
	Actions   []SupplyAction `json:"actions"`
}

// journalEntry is the durable step record of one intent on this host.
type journalEntry struct {
	Agent string `json:"agent"`
	// Step is reserving (before reserve), spawning (before the host call that
	// may create a pane) or spawned (the host returned the pane).
	Step      string `json:"step"`
	Workspace string `json:"workspace_id,omitempty"`
	Tab       string `json:"tab_id,omitempty"`
	Pane      string `json:"pane_id,omitempty"`
	// Reported is the last state the server acknowledged.
	Reported  string    `json:"reported,omitempty"`
	UpdatedAt time.Time `json:"updated_at"`
}

type journal struct {
	Intents map[string]journalEntry `json:"intents"`
}

// DefaultSupplyJournal is ~/.local/state/agentboard/fleet/journal.json.
func DefaultSupplyJournal() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "agentboard", "fleet", "journal.json")
}

// Tick runs one supply pass: reconcile intents this host holds against the
// journal, report launched panes that are gone, then reserve and launch
// pending intents up to the host's launch cap. With seat supply disabled on
// the server it opens no tab.
func (s Supplier) Tick(ctx context.Context) (SupplyReport, error) {
	report := SupplyReport{Actions: []SupplyAction{}}
	lock, err := AcquireLock(s.Journal)
	if err != nil {
		return report, err
	}
	defer lock.Release()
	j, err := loadJournal(s.Journal)
	if err != nil {
		return report, err
	}
	view, err := s.Server.Intents(ctx)
	if err != nil {
		return report, err
	}
	report.Enabled, report.LaunchCap = view.Enabled, view.Host.LaunchCap
	p := &pass{Supplier: s, journal: j, report: &report}
	listed := map[string]bool{}
	busy := 0
	var pending []LaunchIntent
	for _, in := range view.Intents {
		listed[in.ID] = true
		switch in.State {
		case "reserved", "uncertain":
			if inProgress(p.reconcile(ctx, in, view.Enabled)) {
				busy++
			}
		case "launched":
			p.watch(ctx, in)
		case "pending":
			pending = append(pending, in)
		}
	}
	// The server lists every intent this host holds; the rest are closed.
	for id := range j.Intents {
		if !listed[id] {
			delete(j.Intents, id)
		}
	}
	p.save()
	if view.Enabled {
		for _, in := range pending {
			if busy >= view.Host.LaunchCap || p.err != nil {
				break
			}
			if inProgress(p.start(ctx, in)) {
				busy++
			}
		}
	}
	return report, p.err
}

func inProgress(state string) bool { return state == "reserved" || state == "uncertain" }

type pass struct {
	Supplier
	journal journal
	report  *SupplyReport
	err     error
}

func (p *pass) start(ctx context.Context, in LaunchIntent) string {
	if !p.step(in, journalEntry{Agent: in.AgentID, Step: "reserving"}) {
		return ""
	}
	reserved, err := p.Server.Reserve(ctx, in.ID)
	if err != nil {
		p.act(in, "refused", err.Error())
		return ""
	}
	p.act(reserved, "reserved", "")
	return p.launch(ctx, reserved)
}

// launch runs one reserved intent whose journal shows pane creation never
// started. A refusal before the host created anything fails the intent; an
// unknown outcome keeps it occupied as uncertain.
func (p *pass) launch(ctx context.Context, in LaunchIntent) string {
	if _, ok := p.Config.Harnesses[in.Harness]; !ok {
		return p.send(ctx, in, LaunchReport{State: "failed", Reason: fmt.Sprintf("harness %q is not in this host's allowlist", in.Harness)})
	}
	brief := filepath.Join(p.Config.BriefDir, in.AgentID+"--"+in.ID+".md")
	if err := writePrivate(brief, supplyBrief(in)); err != nil {
		return p.send(ctx, in, LaunchReport{State: "failed", Reason: "write brief: " + err.Error()})
	}
	plan, err := PlanSpawn(p.Config, SpawnOptions{Agent: in.AgentID, Harness: in.Harness, Brief: brief, BoardURL: p.BoardURL})
	if err != nil {
		return p.send(ctx, in, LaunchReport{State: "failed", Reason: err.Error()})
	}
	if !p.step(in, journalEntry{Agent: in.AgentID, Step: "spawning"}) {
		return in.State
	}
	result, err := Spawn(ctx, p.Host, plan, true)
	if result.Spawned == nil {
		if NotStarted(err) {
			// Nothing exists on the host, so a retry may launch this intent.
			p.step(in, journalEntry{Agent: in.AgentID, Step: "reserving"})
			return p.send(ctx, in, LaunchReport{State: "failed", Reason: err.Error()})
		}
		return p.send(ctx, in, LaunchReport{State: "uncertain", Reason: "launch outcome unknown: " + errText(err)})
	}
	seat := *result.Spawned
	entry := journalEntry{Agent: in.AgentID, Step: "spawned", Workspace: seat.Workspace, Tab: seat.Tab, Pane: seat.Pane}
	p.step(in, entry)
	if err != nil {
		return p.send(ctx, in, LaunchReport{State: "uncertain", Reason: err.Error(), Workspace: seat.Workspace, Tab: seat.Tab, Pane: seat.Pane})
	}
	return p.confirm(ctx, in, entry, p.LeaseWait)
}

// reconcile settles an intent this host already reserved, after a restart or
// a lost report. Only a journal that shows pane creation never started lets
// the same intent launch again.
func (p *pass) reconcile(ctx context.Context, in LaunchIntent, enabled bool) string {
	entry, ok := p.journal.Intents[in.ID]
	switch {
	case ok && entry.Step == "reserving":
		if !enabled {
			p.act(in, "kept", "seat supply is disabled; launch deferred")
			return in.State
		}
		return p.launch(ctx, in)
	case ok && entry.Step == "spawned":
		tab, found, err := p.seatTab(ctx, in.AgentID)
		switch {
		case err != nil:
			p.act(in, "kept", "host unavailable: "+err.Error())
			return in.State
		case !found || !contains(tab.Panes, entry.Pane):
			return p.send(ctx, in, LaunchReport{State: "uncertain", Reason: "pane " + entry.Pane + " is gone; resolve or abandon this intent"})
		}
		return p.confirm(ctx, in, entry, 0)
	}
	// Spawning, or no entry at all: pane creation may have started.
	tab, found, err := p.seatTab(ctx, in.AgentID)
	if err != nil {
		p.act(in, "kept", "host unavailable: "+err.Error())
		return in.State
	}
	if found {
		entry = journalEntry{Agent: in.AgentID, Step: "spawned", Workspace: tab.Workspace, Tab: tab.Tab, Pane: tab.Panes[0]}
		p.step(in, entry)
		p.act(in, "adopted", "pane "+entry.Pane)
		return p.confirm(ctx, in, entry, 0)
	}
	reason := "pane creation started and no pane exists; resolve or abandon this intent"
	if !ok {
		reason = "reserved with no journal entry on this host; resolve or abandon this intent"
	}
	return p.send(ctx, in, LaunchReport{State: "uncertain", Reason: reason})
}

// watch reports a launched intent closed once its pane is gone, for example
// after seat reap closed it. Reap itself never writes the board.
func (p *pass) watch(ctx context.Context, in LaunchIntent) {
	tabs, err := p.Host.SeatTabs(ctx, p.Config.Workspace)
	if err != nil {
		p.act(in, "kept", "host unavailable: "+err.Error())
		return
	}
	for _, tab := range tabs {
		if contains(tab.Panes, in.Pane) {
			return
		}
	}
	p.send(ctx, in, LaunchReport{State: "closed", Reason: "pane " + in.Pane + " is closed on this host"})
}

// confirm reports launched once the seat's Treehouse lease exists, and
// uncertain while it does not.
func (p *pass) confirm(ctx context.Context, in LaunchIntent, entry journalEntry, wait time.Duration) string {
	r := LaunchReport{Workspace: entry.Workspace, Tab: entry.Tab, Pane: entry.Pane}
	lease, err := p.lease(ctx, in.AgentID, wait)
	switch {
	case err != nil:
		r.State, r.Reason = "uncertain", "pane "+entry.Pane+" started; lease lookup failed: "+err.Error()
	case lease == "":
		r.State, r.Reason = "uncertain", "pane "+entry.Pane+" started; no Treehouse lease held by "+in.AgentID+" yet"
	default:
		r.State, r.Lease = "launched", lease
	}
	return p.send(ctx, in, r)
}

// send reports to the server and journals the acknowledged state. An intent
// that is already uncertain is not re-reported uncertain.
func (p *pass) send(ctx context.Context, in LaunchIntent, r LaunchReport) string {
	if in.State == "uncertain" && r.State == "uncertain" {
		p.act(in, "kept", r.Reason)
		return in.State
	}
	if len(r.Reason) > 500 {
		r.Reason = r.Reason[:500]
	}
	got, err := p.Server.Report(ctx, in.ID, r)
	if err != nil {
		p.act(in, "report_failed", err.Error())
		return in.State
	}
	p.act(in, got.State, r.Reason)
	if entry, ok := p.journal.Intents[in.ID]; ok {
		if got.State == "failed" || got.State == "closed" {
			delete(p.journal.Intents, in.ID)
		} else {
			entry.Reported = got.State
			p.journal.Intents[in.ID] = entry
		}
		p.save()
	}
	return got.State
}

func (p *pass) seatTab(ctx context.Context, agent string) (HostTab, bool, error) {
	tabs, err := p.Host.SeatTabs(ctx, p.Config.Workspace)
	if err != nil {
		return HostTab{}, false, err
	}
	for _, tab := range tabs {
		if tab.Label == agent && len(tab.Panes) > 0 {
			return tab, true, nil
		}
	}
	return HostTab{}, false, nil
}

func (p *pass) lease(ctx context.Context, agent string, wait time.Duration) (string, error) {
	if p.Leases == nil {
		return "", errors.New("no Treehouse lease lister configured")
	}
	poll := p.Poll
	if poll <= 0 {
		poll = 2 * time.Second
	}
	deadline := time.Now().Add(wait)
	for {
		leases, err := p.Leases.List(ctx, p.Config.Root)
		if err != nil {
			return "", err
		}
		for _, l := range leases {
			if l.Holder == agent {
				return l.Path, nil
			}
		}
		if !time.Now().Before(deadline) {
			return "", nil
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(poll):
		}
	}
}

// step journals entry before the action it names; without a durable journal
// no host call runs.
func (p *pass) step(in LaunchIntent, entry journalEntry) bool {
	entry.Reported = p.journal.Intents[in.ID].Reported
	entry.UpdatedAt = time.Now().UTC()
	p.journal.Intents[in.ID] = entry
	p.save()
	if p.err != nil {
		p.act(in, "kept", "journal: "+p.err.Error())
		return false
	}
	return true
}

func (p *pass) save() {
	if p.err == nil {
		p.err = saveJSON(p.Journal, p.journal)
	}
}

func (p *pass) act(in LaunchIntent, action, reason string) {
	p.report.Actions = append(p.report.Actions, SupplyAction{Intent: in.ID, Agent: in.AgentID, Action: action, Reason: reason})
}

func loadJournal(path string) (journal, error) {
	j := journal{Intents: map[string]journalEntry{}}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return j, nil
	}
	if err != nil {
		return j, err
	}
	if err := json.Unmarshal(raw, &j); err != nil {
		return journal{}, fmt.Errorf("%s: %w", path, err)
	}
	if j.Intents == nil {
		j.Intents = map[string]journalEntry{}
	}
	return j, nil
}

func supplyBrief(in LaunchIntent) string {
	return fmt.Sprintf(`# Agentboard seat %s

Seat supply started you for fleet %s, seat %s (harness %s), because the fleet
has backlog. The board is the only authority for what you work on.

1. Register from this pane: agentboard agent register --backend herdr --json
2. Run your agentboard check-in. Backlog refill orders cards to idle fleet
   seats; claim only what the board assigns or orders to you.
`, in.AgentID, in.FleetID, in.SeatID, in.Harness)
}

func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}

func errText(err error) string {
	if err == nil {
		return "no pane returned"
	}
	return err.Error()
}
