package seatops

import (
	"context"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// Landed is the landed-work gate: a clean tree whose HEAD is reachable from a
// remote branch or origin/main. Empty means landed; anything else says why not.
// It works for any Git checkout, Treehouse slot or not.
func Landed(dir string) string {
	git := func(args ...string) (string, error) {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.Output()
		return strings.TrimSpace(string(out)), err
	}
	if dirty, err := git("status", "--porcelain"); err != nil || dirty != "" {
		if err != nil {
			return "cannot read worktree status"
		}
		return "uncommitted changes"
	}
	head, err := git("rev-parse", "HEAD")
	if err != nil || head == "" {
		return "cannot read HEAD"
	}
	if remotes, err := git("branch", "-r", "--contains", head); err == nil && remotes != "" {
		return ""
	}
	if _, err := git("merge-base", "--is-ancestor", head, "origin/main"); err == nil {
		return ""
	}
	return "HEAD is not reachable from any remote branch"
}

// Lease is one leased worktree in a Treehouse pool.
type Lease struct {
	Root      string `json:"root"`
	Path      string `json:"path"`
	Holder    string `json:"lease_holder"`
	Branch    string `json:"branch"`
	Processes []any  `json:"processes"`
}

// Leases lists and returns leased worktrees. It is optional: without
// configured pool roots, reap never looks at worktree pools.
type Leases interface {
	List(ctx context.Context, root string) ([]Lease, error)
	Return(ctx context.Context, lease Lease) error
}

// ReapAction is one thing reap did, would do, or refused to do.
type ReapAction struct {
	Kind   string `json:"kind"` // close_pane, return_lease, expired_claim, retire_candidate
	Agent  string `json:"agent,omitempty"`
	Pane   string `json:"pane,omitempty"`
	Path   string `json:"path,omitempty"`
	Task   string `json:"task,omitempty"`
	Done   bool   `json:"done"`
	Reason string `json:"reason"`
}

// ReapReport is the bounded JSON summary of one reap run.
type ReapReport struct {
	DryRun  bool         `json:"dry_run"`
	Actions []ReapAction `json:"actions"`
	Kept    []Skipped    `json:"kept,omitempty"`
}

// Reap closes finished seat panes and returns their landed leases. A seat is
// finished when it has idled for ReapAfter with no open owned task and no
// unread message, and its checkout has landed. Claims are never released and
// identities are never retired: expired claims and identities with no session
// are reported for the captain. With apply false it changes nothing anywhere.
func Reap(ctx context.Context, board Board, host Host, leases Leases, cfg Config, now time.Time, apply bool) (ReapReport, error) {
	report := ReapReport{DryRun: !apply}
	if _, err := os.Stat(cfg.KillSwitch); err == nil {
		report.Kept = append(report.Kept, Skipped{Reason: "kill switch present: " + cfg.KillSwitch})
		return report, nil
	}
	lock, err := AcquireLock(cfg.StateFile)
	if err != nil {
		return report, err
	}
	defer lock.Release()
	state, err := LoadState(cfg.StateFile)
	if err != nil {
		return report, err
	}
	panes, err := host.Agents(ctx)
	if err != nil {
		return report, err
	}
	agents, err := board.Agents(ctx)
	if err != nil {
		return report, err
	}
	seats, skipped := DiscoverSeats(panes, agents, cfg)
	// A retired identity still occupying a pane is a reap candidate too.
	byID := map[string]BoardAgent{}
	for _, a := range agents {
		byID[a.ID] = a
	}
	for _, s := range skipped {
		if s.Reason == "identity retired" {
			for _, p := range panes {
				if p.Pane == s.Pane {
					agent, ok := byID[s.Agent]
					if !ok {
						agent = BoardAgent{ID: s.Agent}
					}
					agent.RetiredAt = &now
					seats = append(seats, Seat{Agent: agent, Host: p})
				}
			}
		}
	}
	live := map[string]bool{}
	for _, p := range panes {
		if p.Name != "" {
			live[p.Name] = true
		}
	}
	openOwned := map[string][]Task{}
	for _, seat := range seats {
		id := seat.Agent.ID
		prev := state.Seats[id]
		if prev.Session != seat.Host.Session.Value {
			prev = SeatState{Session: seat.Host.Session.Value}
		}
		idle := (seat.Host.Status == "idle" || seat.Host.Status == "done")
		if idle {
			tail, err := host.Read(ctx, seat.Host.Pane, 20)
			idle = err == nil && !busyText.MatchString(lastLines(tail, 20))
		}
		if !idle {
			prev.IdleSince = time.Time{}
			state.Seats[id] = prev
			report.Kept = append(report.Kept, Skipped{Agent: id, Pane: seat.Host.Pane, Reason: "not idle"})
			continue
		}
		if prev.IdleSince.IsZero() {
			prev.IdleSince = now
		}
		state.Seats[id] = prev
		owned, err := board.OwnedTasks(ctx, id)
		if err != nil {
			report.Kept = append(report.Kept, Skipped{Agent: id, Pane: seat.Host.Pane, Reason: "board read failed: " + err.Error()})
			continue
		}
		openOwned[id] = owned
		unread, err := board.Unread(ctx, id)
		if err != nil {
			report.Kept = append(report.Kept, Skipped{Agent: id, Pane: seat.Host.Pane, Reason: "board read failed: " + err.Error()})
			continue
		}
		why := ""
		switch {
		case seat.Agent.Availability.State != "" && seat.Agent.Availability.State != "active":
			why = "availability " + seat.Agent.Availability.State
		case now.Sub(prev.IdleSince) < cfg.ReapAfter.Duration:
			why = "idle less than " + cfg.ReapAfter.String()
		case len(owned) > 0:
			why = "owns open task " + owned[0].ID
		case len(unread) > 0:
			why = "has unread messages"
		default:
			if seat.Host.Cwd == "" {
				why = "unknown working directory"
			} else {
				why = Landed(seat.Host.Cwd)
			}
		}
		if why != "" {
			report.Kept = append(report.Kept, Skipped{Agent: id, Pane: seat.Host.Pane, Reason: why})
			continue
		}
		action := ReapAction{Kind: "close_pane", Agent: id, Pane: seat.Host.Pane, Reason: "finished: idle, no open task, no unread, work landed"}
		if apply {
			// Same recipient fence as a nudge: never close a pane whose
			// occupant or state changed since it was judged finished.
			current, err := host.Agent(ctx, seat.Host.Pane)
			switch {
			case err != nil:
				action.Reason = "recheck failed: " + err.Error()
			case current.Name != id || current.Session.Value != seat.Host.Session.Value || current.Kind != seat.Host.Kind || current.StateChangeSeq != seat.Host.StateChangeSeq:
				action.Reason = "pane changed before close"
			case current.Status != "idle" && current.Status != "done":
				action.Reason = "pane state changed before close"
			default:
				tail, err := host.Read(ctx, seat.Host.Pane, 20)
				switch {
				case err != nil:
					action.Reason = "recheck failed: " + err.Error()
				case busyText.MatchString(lastLines(tail, 20)):
					action.Reason = "pane became busy before close"
				default:
					if err := host.ClosePane(ctx, seat.Host.Pane); err != nil {
						action.Reason = "close failed: " + err.Error()
					} else {
						action.Done = true
						delete(live, id)
						delete(state.Seats, id)
					}
				}
			}
		}
		report.Actions = append(report.Actions, action)
	}
	if leases != nil {
		avail := map[string]string{}
		for _, a := range agents {
			avail[a.ID] = a.Availability.State
		}
		for _, root := range cfg.TreehouseRoots {
			listed, err := leases.List(ctx, root)
			if err != nil {
				report.Kept = append(report.Kept, Skipped{Reason: "lease list " + root + ": " + err.Error()})
				continue
			}
			for _, lease := range listed {
				lease.Root = root
				why := ""
				switch {
				case lease.Holder == "":
					why = "lease has no recorded holder"
				case cfg.excluded(lease.Holder, "") != "":
					why = cfg.excluded(lease.Holder, "")
				case avail[lease.Holder] != "" && avail[lease.Holder] != "active":
					why = "availability " + avail[lease.Holder]
				case live[lease.Holder]:
					why = "holder still has a live session"
				case len(lease.Processes) > 0:
					why = "processes running in the worktree"
				}
				if why == "" {
					owned, ok := openOwned[lease.Holder]
					if !ok {
						if owned, err = board.OwnedTasks(ctx, lease.Holder); err != nil {
							why = "board read failed: " + err.Error()
						}
					}
					if why == "" && len(owned) > 0 {
						why = "holder owns open task " + owned[0].ID
					}
				}
				if why == "" {
					why = Landed(lease.Path)
				}
				if why != "" {
					report.Kept = append(report.Kept, Skipped{Agent: lease.Holder, Reason: lease.Path + ": " + why})
					continue
				}
				action := ReapAction{Kind: "return_lease", Agent: lease.Holder, Path: lease.Path, Reason: "holder has no session or open task; work landed"}
				if apply {
					if err := leases.Return(ctx, lease); err != nil {
						action.Reason = "return failed: " + err.Error()
					} else {
						action.Done = true
					}
				}
				report.Actions = append(report.Actions, action)
			}
		}
	}
	// Report-only: the board keeps these until a captain or owner acts.
	for _, a := range agents {
		if a.RetiredAt != nil || a.Kind != "seat" || live[a.ID] {
			continue
		}
		owned, err := board.OwnedTasks(ctx, a.ID)
		if err != nil {
			continue
		}
		sortTasks(owned)
		expired := 0
		for _, t := range owned {
			if t.ClaimExpired {
				expired++
				report.Actions = append(report.Actions, ReapAction{Kind: "expired_claim", Agent: a.ID, Task: t.ID, Reason: "claim expired and owner has no live session; reclaim, release or hand off explicitly"})
			}
		}
		if len(owned) == 0 {
			report.Actions = append(report.Actions, ReapAction{Kind: "retire_candidate", Agent: a.ID, Reason: "no live session and no open task; retire with `agentboard agent retire` if this identity is finished"})
		}
	}
	sort.SliceStable(report.Actions, func(i, j int) bool { return report.Actions[i].Kind < report.Actions[j].Kind })
	if !apply {
		return report, nil
	}
	return report, state.Save(cfg.StateFile)
}
