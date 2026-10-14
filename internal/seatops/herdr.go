// Package seatops nudges idle Herdr-hosted seats toward their board check-in
// and reaps finished seats. It never writes to the board: the board stays the
// only authority, and a nudge carries no instruction beyond "check in".
package seatops

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// HostAgent is one agent session in a host pane (Herdr `agent list|get`).
type HostAgent struct {
	Pane           string `json:"pane_id"`
	Workspace      string `json:"workspace_id"`
	Name           string `json:"name"`
	Kind           string `json:"agent"`
	Status         string `json:"agent_status"`
	Cwd            string `json:"cwd"`
	StateChangeSeq int64  `json:"state_change_seq"`
	Session        struct {
		Value string `json:"value"`
	} `json:"agent_session"`
}

// HostTab is one tab in the seat workspace and the panes it holds.
type HostTab struct {
	Workspace string   `json:"workspace_id"`
	Tab       string   `json:"tab_id"`
	Label     string   `json:"label"`
	Panes     []string `json:"panes"`
}

// Host is the terminal workspace that runs seat sessions. Herdr is the only
// implementation today; any host that can list agents with a status and a
// native session identity, read recent output, prompt, close, name a detected
// agent, open a new tab that runs a command, and list the seat workspace's
// tabs fits.
type Host interface {
	Agents(ctx context.Context) ([]HostAgent, error)
	Agent(ctx context.Context, pane string) (HostAgent, error)
	Read(ctx context.Context, pane string, lines int) (string, error)
	Prompt(ctx context.Context, pane, text string) error
	ClosePane(ctx context.Context, pane string) error
	// NameAgent names the agent the host detected in pane. It fails while no
	// agent has been detected there yet.
	NameAgent(ctx context.Context, pane, name string) error
	// Spawn opens a new tab and runs req.Argv in its own fresh pane. It never
	// sends input to a pane that existed before the call.
	Spawn(ctx context.Context, req SpawnRequest) (SpawnedSeat, error)
	// SeatTabs lists the tabs, with their panes, of the one workspace
	// labelled workspace. A workspace that does not exist has no tabs.
	SeatTabs(ctx context.Context, workspace string) ([]HostTab, error)
}

// ErrAgentBlocked means the host rejected a prompt before sending any input.
var ErrAgentBlocked = errors.New("herdr: agent_blocked")

// HerdrCLI shells out to the herdr binary.
type HerdrCLI struct{ Bin string }

func (h HerdrCLI) run(ctx context.Context, timeout time.Duration, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	bin := h.Bin
	if bin == "" {
		bin = "herdr"
	}
	var stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		detail := strings.TrimSpace(stderr.String() + " " + string(out))
		if strings.Contains(detail, "agent_blocked") {
			return nil, ErrAgentBlocked
		}
		if len(detail) > 300 {
			detail = detail[:300]
		}
		return nil, fmt.Errorf("herdr %s: %w: %s", strings.Join(args[:min(2, len(args))], " "), err, detail)
	}
	return out, nil
}

func (h HerdrCLI) Agents(ctx context.Context) ([]HostAgent, error) {
	out, err := h.run(ctx, 30*time.Second, "agent", "list")
	if err != nil {
		return nil, err
	}
	var decoded struct {
		Result struct {
			Agents []HostAgent `json:"agents"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &decoded); err != nil {
		return nil, fmt.Errorf("herdr agent list: %w", err)
	}
	return decoded.Result.Agents, nil
}

func (h HerdrCLI) Agent(ctx context.Context, pane string) (HostAgent, error) {
	out, err := h.run(ctx, 15*time.Second, "agent", "get", pane)
	if err != nil {
		return HostAgent{}, err
	}
	var decoded struct {
		Result struct {
			Agent HostAgent `json:"agent"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &decoded); err != nil {
		return HostAgent{}, fmt.Errorf("herdr agent get: %w", err)
	}
	return decoded.Result.Agent, nil
}

func (h HerdrCLI) Read(ctx context.Context, pane string, lines int) (string, error) {
	out, err := h.run(ctx, 15*time.Second, "agent", "read", pane, "--source", "detection", "--lines", fmt.Sprint(lines))
	return string(out), err
}

func (h HerdrCLI) Prompt(ctx context.Context, pane, text string) error {
	_, err := h.run(ctx, 30*time.Second, "agent", "prompt", pane, text)
	return err
}

func (h HerdrCLI) ClosePane(ctx context.Context, pane string) error {
	_, err := h.run(ctx, 15*time.Second, "pane", "close", pane)
	return err
}

func (h HerdrCLI) NameAgent(ctx context.Context, pane, name string) error {
	_, err := h.run(ctx, 15*time.Second, "agent", "rename", pane, name)
	return err
}

// Spawn finds the one workspace labelled req.Workspace, or creates it, refuses
// a tab already labelled req.Label there, then creates the seat's tab and runs
// argv in that tab's root pane. Herdr 0.9.0 `pane run` types into a pane, so it
// is only ever pointed at the pane `tab create` just returned. Every refusal
// before `tab create` is marked NotStarted.
func (h HerdrCLI) Spawn(ctx context.Context, req SpawnRequest) (SpawnedSeat, error) {
	var seat SpawnedSeat
	id, err := h.workspace(ctx, req.Workspace)
	if err != nil {
		return seat, notStarted{err}
	}
	if id == "" {
		out, err := h.run(ctx, 15*time.Second, "workspace", "create", "--cwd", req.Cwd, "--label", req.Workspace, "--no-focus")
		if err != nil {
			return seat, notStarted{err}
		}
		var created struct {
			Result struct {
				Workspace struct {
					ID string `json:"workspace_id"`
				} `json:"workspace"`
			} `json:"result"`
		}
		if json.Unmarshal(out, &created) != nil || created.Result.Workspace.ID == "" {
			return seat, notStarted{errors.New("herdr workspace create: no workspace_id in response")}
		}
		seat.Workspace, seat.CreatedWorkspace = created.Result.Workspace.ID, true
	} else {
		seat.Workspace = id
		tabs, err := h.tabs(ctx, id)
		if err != nil {
			return seat, notStarted{err}
		}
		for _, t := range tabs {
			if t.Label == req.Label {
				return seat, notStarted{fmt.Errorf("refuses: herdr tab %s in workspace %s is already labelled %s: %w", t.Tab, seat.Workspace, req.Label, ErrSeatExists)}
			}
		}
	}
	args := []string{"tab", "create", "--workspace", seat.Workspace, "--cwd", req.Cwd, "--label", req.Label, "--no-focus"}
	for _, key := range sortedEnv(req.Env) {
		args = append(args, "--env", key+"="+req.Env[key])
	}
	out, err := h.run(ctx, 15*time.Second, args...)
	if err != nil {
		return seat, err
	}
	var tab struct {
		Result struct {
			Tab struct {
				ID string `json:"tab_id"`
			} `json:"tab"`
			RootPane struct {
				ID string `json:"pane_id"`
			} `json:"root_pane"`
		} `json:"result"`
	}
	if json.Unmarshal(out, &tab) != nil || tab.Result.Tab.ID == "" || tab.Result.RootPane.ID == "" {
		return seat, errors.New("herdr tab create: no tab_id or root pane_id in response")
	}
	seat.Tab, seat.Pane = tab.Result.Tab.ID, tab.Result.RootPane.ID
	if _, err := h.run(ctx, 15*time.Second, "pane", "run", seat.Pane, shellCommand(req.Argv)); err != nil {
		return seat, fmt.Errorf("new pane %s (tab %s) did not confirm its launch command; inspect it before closing: %w", seat.Pane, seat.Tab, err)
	}
	return seat, nil
}

func (h HerdrCLI) SeatTabs(ctx context.Context, workspace string) ([]HostTab, error) {
	id, err := h.workspace(ctx, workspace)
	if err != nil || id == "" {
		return nil, err
	}
	tabs, err := h.tabs(ctx, id)
	if err != nil {
		return nil, err
	}
	out, err := h.run(ctx, 15*time.Second, "pane", "list", "--workspace", id)
	if err != nil {
		return nil, err
	}
	var panes struct {
		Result struct {
			Panes []struct {
				ID  string `json:"pane_id"`
				Tab string `json:"tab_id"`
			} `json:"panes"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &panes); err != nil {
		return nil, fmt.Errorf("herdr pane list: %w", err)
	}
	for i := range tabs {
		for _, p := range panes.Result.Panes {
			if p.Tab == tabs[i].Tab {
				tabs[i].Panes = append(tabs[i].Panes, p.ID)
			}
		}
	}
	return tabs, nil
}

// workspace returns the ID of the one workspace labelled label, or "" when
// none is. Several workspaces sharing the label is a refusal.
func (h HerdrCLI) workspace(ctx context.Context, label string) (string, error) {
	out, err := h.run(ctx, 15*time.Second, "workspace", "list")
	if err != nil {
		return "", err
	}
	var spaces struct {
		Result struct {
			Workspaces []struct {
				ID    string `json:"workspace_id"`
				Label string `json:"label"`
			} `json:"workspaces"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &spaces); err != nil {
		return "", fmt.Errorf("herdr workspace list: %w", err)
	}
	var matches []string
	for _, w := range spaces.Result.Workspaces {
		if w.Label == label {
			matches = append(matches, w.ID)
		}
	}
	switch len(matches) {
	case 0:
		return "", nil
	case 1:
		return matches[0], nil
	default:
		return "", fmt.Errorf("refuses: %d herdr workspaces are labelled %q (%s); rename or close the extras", len(matches), label, strings.Join(matches, " "))
	}
}

func (h HerdrCLI) tabs(ctx context.Context, workspace string) ([]HostTab, error) {
	out, err := h.run(ctx, 15*time.Second, "tab", "list", "--workspace", workspace)
	if err != nil {
		return nil, err
	}
	var listed struct {
		Result struct {
			Tabs []struct {
				ID    string `json:"tab_id"`
				Label string `json:"label"`
			} `json:"tabs"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &listed); err != nil {
		return nil, fmt.Errorf("herdr tab list: %w", err)
	}
	tabs := make([]HostTab, 0, len(listed.Result.Tabs))
	for _, t := range listed.Result.Tabs {
		tabs = append(tabs, HostTab{Workspace: workspace, Tab: t.ID, Label: t.Label})
	}
	return tabs, nil
}
