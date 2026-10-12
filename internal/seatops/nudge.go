package seatops

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

var (
	busyText     = regexp.MustCompile(`(?i)esc to interrupt|Calling tools \(|Working \(|Thinking \(|\bThinking\.\.\.`)
	chrome       = regexp.MustCompile(`for shortcuts|Ask Codex|esc to |Tip:|Shift\+Tab|Voice input|↓ to select|Worked for|Context compacted|always-approve|^[\s─━╭╮╰╯│█▌]*$|^\s*[›❯>]\s*$|background terminal|/ps to view|· (high|low|medium|xhigh)\s*$|ctrl\+[a-z]`)
	paneQuestion = regexp.MustCompile(`(?i)(awaiting|waiting (on|for)|pending|paused at|blocked on)[^.\n]{0,50}(coordinator|captain|approval|decision|your (call|answer|go-ahead))|decision request|\b(should I|shall I|do you want|want me to|would you like|can you confirm|please confirm)\b[^\n]*\?`)
	taskWaiting  = regexp.MustCompile(`(?i)decision request|needs? (a |an explicit )?(coordinator |captain )?(decision|approval|authori[sz]ation)|(waiting|wait|pending|awaiting|blocked)( on| for)?( the)? (captain|coordinator)|(captain|coordinator)('s)? (decision|approval|answer|go-ahead|authori[sz]ation)|awaiting (approval|decision)`)
)

// SeatView is everything one decision needs about one seat.
type SeatView struct {
	Agent    BoardAgent
	Host     HostAgent
	Tail     string // recent host output
	Owned    []Task
	Unread   []Message
	Waiting  map[string]time.Time // owned task -> when it started waiting on the captain/coordinator
	Previous SeatState
}

// Decision is the outcome for one seat in one run.
type Decision struct {
	Agent   string   `json:"agent"`
	Pane    string   `json:"pane,omitempty"`
	Action  string   `json:"action"` // skip, noop, hold, nudge, nudged, abort, error
	State   string   `json:"state,omitempty"`
	Reason  string   `json:"reason,omitempty"`
	Sig     string   `json:"sig,omitempty"`
	Mode    string   `json:"mode,omitempty"`
	Prompt  string   `json:"prompt,omitempty"`
	Waiting []string `json:"waiting_on,omitempty"`
	// next is the seat state to persist when the decision is carried out.
	next SeatState
	seq  int64
}

// Decide classifies one seat and chooses whether to nudge it. It is pure.
func Decide(v SeatView, now time.Time, cfg Config) Decision {
	d := Decision{Agent: v.Agent.ID, Pane: v.Host.Pane, seq: v.Host.StateChangeSeq}
	next := v.Previous
	if next.Session != v.Host.Session.Value {
		next = SeatState{Session: v.Host.Session.Value}
	}
	tail := lastLines(v.Tail, 20)
	busy := v.Host.Status == "working" || busyText.MatchString(tail)
	switch {
	case busy:
		next.IdleSince = time.Time{}
		d.State = "busy"
	case v.Host.Status == "idle" || v.Host.Status == "done" || v.Host.Status == "blocked":
		if next.IdleSince.IsZero() {
			next.IdleSince = now
		}
		d.State = "idle"
	default:
		next.IdleSince = time.Time{}
		d.State = "unclear:" + v.Host.Status
	}
	d.next = next
	if d.State != "idle" {
		d.Action, d.Reason = "noop", d.State
		return d
	}
	question := ""
	if v.Host.Status != "blocked" {
		for _, line := range meaningfulTail(v.Tail, 6) {
			if paneQuestion.MatchString(line) {
				question = line
			}
		}
	}
	for id := range v.Waiting {
		d.Waiting = append(d.Waiting, id)
	}
	sort.Strings(d.Waiting)
	if v.Host.Status == "blocked" || question != "" || len(d.Waiting) > 0 {
		d.State = "waiting"
	}
	if v.Host.Status == "blocked" {
		d.Action, d.Reason = "noop", "approval prompt open in pane"
		return d
	}
	idleFor := now.Sub(next.IdleSince)
	var reasons, sig []string
	if d.State == "waiting" {
		// A seat parked on a decision only hears about messages that arrived
		// after it started waiting; it never gets pointed at new work.
		since := now.Add(-72 * time.Hour)
		for _, at := range v.Waiting {
			if at.After(since) {
				since = at
			}
		}
		var answers []string
		for _, m := range v.Unread {
			if m.CreatedAt.After(since) {
				answers = append(answers, fmt.Sprint(m.ID))
			}
		}
		if len(answers) == 0 {
			d.Action, d.Reason = "noop", "waiting with no new message"
			return d
		}
		sort.Strings(answers)
		d.Mode = "answer"
		sig = append([]string{"ans"}, answers...)
		if len(d.Waiting) == 0 {
			d.Prompt = fmt.Sprintf("Agentboard nudge (automated, no reply needed): you asked a question; new message(s) %s may answer it: read them (agentboard msg list --unread). If answered, resume your work; otherwise continue your agentboard check-in.", strings.Join(answers, ", "))
		} else {
			waitingOn := strings.Join(d.Waiting, ", ")
			d.Prompt = fmt.Sprintf("Agentboard nudge (automated, no reply needed): you are waiting on the captain/coordinator (%s). New message(s) %s may answer it: read them (agentboard msg list --unread). If answered, resume that task; if not, stay parked and do not pick up new work.", waitingOn, strings.Join(answers, ", "))
		}
	} else {
		if len(v.Unread) > 0 {
			ids := make([]string, 0, len(v.Unread))
			for _, m := range v.Unread {
				ids = append(ids, fmt.Sprint(m.ID))
			}
			sort.Strings(ids)
			reasons = append(reasons, fmt.Sprintf("you have %d unread message(s)", len(ids)))
			sig = append(append(sig, "u"), ids...)
		}
		var current []Task
		for _, t := range v.Owned {
			if t.Status == "in_progress" {
				current = append(current, t)
			}
		}
		sortTasks(current)
		var expired []string
		for _, t := range current {
			if t.ClaimExpired {
				expired = append(expired, t.ID)
			}
		}
		if len(expired) > 0 {
			reasons = append(reasons, "your claim on "+strings.Join(expired, ", ")+" expired: renew, finish or park it")
			sig = append(append(sig, "x"), expired...)
		}
		pick, _ := PickCard(v.Owned, v.Waiting)
		if pick != nil && !containsTask(current, pick.ID) && (len(current) == 0 || priority(*pick) < priority(current[0])) {
			action := "claim it"
			if pick.Status == "blocked" {
				action = "check whether its blocker cleared and resume it, or report the blocker"
			}
			reasons = append(reasons, fmt.Sprintf("your highest-priority task is %s (P%d): %s", pick.ID, priority(*pick), action))
			sig = append(sig, "s", pick.ID)
		}
		if len(reasons) == 0 && len(current) > 0 && idleFor >= cfg.IdleAfter.Duration {
			first := current[0]
			if pick != nil && containsTask(current, pick.ID) {
				first = *pick
			}
			reasons = append(reasons, fmt.Sprintf("you have been idle %dm with open work; continue %s (P%d)", int(idleFor/time.Minute), first.ID, priority(first)))
			ids := make([]string, 0, len(current))
			for _, t := range current {
				ids = append(ids, t.ID)
			}
			sig = append(append(sig, "i"), ids...)
		}
		if len(reasons) == 0 {
			d.Action, d.Reason = "noop", "idle with nothing to do"
			return d
		}
		d.Mode = "work"
		d.Prompt = "Agentboard nudge (automated, no reply needed): " + strings.Join(reasons, "; ") + ". Run your agentboard check-in now: read your inbox (agentboard msg list --unread), reconcile your owned tasks, claim or renew, then continue. Finish or explicitly park current work before starting anything new; never abandon a claimed task."
	}
	sum := sha256.Sum256([]byte(strings.Join(sig, "|")))
	d.Sig = hex.EncodeToString(sum[:6])
	switch {
	case next.LastSig == d.Sig:
		d.Action, d.Reason = "hold", "already nudged for this reason set"
	case !next.LastNudgeAt.IsZero() && now.Sub(next.LastNudgeAt) < cfg.MinGap.Duration:
		d.Action, d.Reason = "hold", "rate limit"
	default:
		d.Action = "nudge"
		next.LastNudgeAt, next.LastSig, next.LastMode = now, d.Sig, d.Mode
	}
	d.next = next
	return d
}

// PickCard chooses the owned task an idle seat should work on. Tasks waiting on
// the captain/coordinator are never candidates. Within the top priority an
// actionable card beats a parked one, and at P0/P1 an already claimed card
// wins; otherwise the oldest card wins. A parked P0 always outranks a P3.
func PickCard(owned []Task, waiting map[string]time.Time) (*Task, string) {
	var eligible []Task
	for _, t := range owned {
		switch t.Status {
		case "assigned", "open", "in_progress", "blocked":
		default:
			continue
		}
		if _, ok := waiting[t.ID]; ok || t.HeldBy != nil {
			continue
		}
		eligible = append(eligible, t)
	}
	if len(eligible) == 0 {
		return nil, "no eligible task"
	}
	best := priority(eligible[0])
	for _, t := range eligible {
		best = min(best, priority(t))
	}
	var top []Task
	for _, t := range eligible {
		if priority(t) == best {
			top = append(top, t)
		}
	}
	sort.SliceStable(top, func(i, j int) bool {
		a, b := top[i], top[j]
		if (a.Status == "blocked") != (b.Status == "blocked") {
			return b.Status == "blocked"
		}
		if best <= 1 && claimed(a) != claimed(b) {
			return claimed(a)
		}
		return taskLess(a, b)
	})
	pick := top[0]
	if best <= 1 && claimed(pick) {
		return &pick, fmt.Sprintf("claimed P%d", best)
	}
	return &pick, fmt.Sprintf("highest priority P%d, oldest", best)
}

func taskLess(a, b Task) bool {
	if priority(a) != priority(b) {
		return priority(a) < priority(b)
	}
	if !a.CreatedAt.Equal(b.CreatedAt) {
		return a.CreatedAt.Before(b.CreatedAt)
	}
	return a.ID < b.ID
}

func sortTasks(tasks []Task) {
	sort.SliceStable(tasks, func(i, j int) bool { return taskLess(tasks[i], tasks[j]) })
}

func containsTask(tasks []Task, id string) bool {
	for _, t := range tasks {
		if t.ID == id {
			return true
		}
	}
	return false
}

func lastLines(text string, n int) string {
	var lines []string
	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

func meaningfulTail(text string, n int) []string {
	var lines []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !chrome.MatchString(line) {
			lines = append(lines, line)
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}

// Seat pairs a board identity with the one host pane named after it.
type Seat struct {
	Agent BoardAgent
	Host  HostAgent
}

// Skipped is a seat or pane left alone, with why.
type Skipped struct {
	Agent  string `json:"agent,omitempty"`
	Pane   string `json:"pane,omitempty"`
	Reason string `json:"reason"`
}

// DiscoverSeats maps named host panes to board identities. A pane is a seat
// only when its host name equals a live board agent ID, exactly one pane has
// that name, and the host agent kind matches the identity's harness.
func DiscoverSeats(panes []HostAgent, agents []BoardAgent, cfg Config) ([]Seat, []Skipped) {
	byID := map[string]BoardAgent{}
	for _, a := range agents {
		byID[a.ID] = a
	}
	named := map[string][]HostAgent{}
	for _, p := range panes {
		if p.Name != "" {
			named[p.Name] = append(named[p.Name], p)
		}
	}
	names := make([]string, 0, len(named))
	for name := range named {
		names = append(names, name)
	}
	sort.Strings(names)
	var seats []Seat
	var skipped []Skipped
	for _, name := range names {
		group := named[name]
		agent, ok := byID[name]
		why := ""
		switch {
		case !ok:
			why = "pane name is not a board agent"
		case len(group) != 1:
			why = fmt.Sprintf("%d panes share this name", len(group))
		case agent.RetiredAt != nil:
			why = "identity retired"
		case group[0].Kind != agent.Harness:
			why = fmt.Sprintf("pane runs %q, identity harness is %q", group[0].Kind, agent.Harness)
		default:
			why = cfg.excluded(name, group[0].Workspace)
		}
		if why != "" {
			skipped = append(skipped, Skipped{Agent: name, Pane: group[0].Pane, Reason: why})
			continue
		}
		seats = append(seats, Seat{Agent: agent, Host: group[0]})
	}
	return seats, skipped
}

// NudgeReport is the bounded JSON summary of one nudge run.
type NudgeReport struct {
	DryRun    bool       `json:"dry_run"`
	Decisions []Decision `json:"decisions"`
	Skipped   []Skipped  `json:"skipped,omitempty"`
}

// Nudge runs one pass. With apply false it changes nothing anywhere.
func Nudge(ctx context.Context, board Board, host Host, cfg Config, now time.Time, apply bool) (NudgeReport, error) {
	report := NudgeReport{DryRun: !apply}
	if _, err := os.Stat(cfg.KillSwitch); err == nil {
		report.Skipped = append(report.Skipped, Skipped{Reason: "kill switch present: " + cfg.KillSwitch})
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
	report.Skipped = skipped
	for _, seat := range seats {
		d := nudgeSeat(ctx, board, host, cfg, seat, state.Seats[seat.Agent.ID], now, apply)
		if d.Action == "nudged" || d.Action == "noop" || d.Action == "hold" {
			state.Seats[seat.Agent.ID] = d.next
		}
		report.Decisions = append(report.Decisions, d)
	}
	if !apply {
		return report, nil
	}
	state.LastRun = now
	return report, state.Save(cfg.StateFile)
}

func nudgeSeat(ctx context.Context, board Board, host Host, cfg Config, seat Seat, previous SeatState, now time.Time, apply bool) Decision {
	fail := func(err error) Decision {
		return Decision{Agent: seat.Agent.ID, Pane: seat.Host.Pane, Action: "error", Reason: err.Error()}
	}
	if state := seat.Agent.Availability.State; state != "" && state != "active" {
		return Decision{Agent: seat.Agent.ID, Pane: seat.Host.Pane, Action: "skip", Reason: "availability " + state, next: previous}
	}
	tail, err := host.Read(ctx, seat.Host.Pane, 40)
	if err != nil {
		return fail(err)
	}
	view := SeatView{Agent: seat.Agent, Host: seat.Host, Tail: tail, Previous: previous, Waiting: map[string]time.Time{}}
	if view.Owned, err = board.OwnedTasks(ctx, seat.Agent.ID); err != nil {
		return fail(err)
	}
	for _, t := range view.Owned {
		if t.Status != "blocked" && t.Status != "review" {
			continue
		}
		body, at, err := board.LastBody(ctx, t.ID)
		if err != nil {
			// Never decide from a partial board read.
			return fail(err)
		}
		if taskWaiting.MatchString(body) {
			view.Waiting[t.ID] = at
		}
	}
	if view.Unread, err = board.Unread(ctx, seat.Agent.ID); err != nil {
		return fail(err)
	}
	d := Decide(view, now, cfg)
	if d.Action != "nudge" || !apply {
		return d
	}
	// Recheck the exact recipient immediately before sending: same pane name,
	// same native session, same agent kind, and no state change since the
	// snapshot. Herdr has no conditional prompt, so a residual window remains;
	// the nudge carries no authority, so losing that race costs one turn.
	current, err := host.Agent(ctx, seat.Host.Pane)
	if err != nil {
		d.Action, d.Reason = "abort", "recheck failed: "+err.Error()
		return d
	}
	recheck, _ := host.Read(ctx, seat.Host.Pane, 20)
	switch {
	case current.Name != seat.Agent.ID, current.Session.Value != seat.Host.Session.Value, current.Kind != seat.Host.Kind:
		d.Action, d.Reason = "abort", "pane occupant changed"
	case current.StateChangeSeq != d.seq || (current.Status != "idle" && current.Status != "done"):
		d.Action, d.Reason = "abort", "pane state changed before send"
	case busyText.MatchString(lastLines(recheck, 20)):
		d.Action, d.Reason = "abort", "pane became busy before send"
	}
	if d.Action == "abort" {
		return d
	}
	if err := host.Prompt(ctx, seat.Host.Pane, d.Prompt); err != nil {
		if errors.Is(err, ErrAgentBlocked) {
			d.Action, d.Reason = "abort", "host rejected: agent blocked"
			return d
		}
		// Delivery is uncertain: record the attempt so the same reason set is
		// never replayed. A new reason set nudges again after the gap.
		d.Action, d.Reason = "nudged", "uncertain: "+err.Error()
		return d
	}
	d.Action = "nudged"
	return d
}
