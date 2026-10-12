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

// Host is the terminal workspace that runs seat sessions. Herdr is the only
// implementation today; any host that can list agents with a status and a
// native session identity, read recent output, prompt and close fits.
type Host interface {
	Agents(ctx context.Context) ([]HostAgent, error)
	Agent(ctx context.Context, pane string) (HostAgent, error)
	Read(ctx context.Context, pane string, lines int) (string, error)
	Prompt(ctx context.Context, pane, text string) error
	ClosePane(ctx context.Context, pane string) error
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
