package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"reflect"
	"strings"

	"github.com/carverauto/agentboard"
	"github.com/carverauto/agentboard/internal/client"
	"github.com/spf13/cobra"
)

type seatResolution struct {
	Binding map[string]string `json:"binding"`
	Env     map[string]string `json:"environment"`
}

type seatTaskClaim struct {
	ID, Status string
	Owner      string `json:"assignee_id"`
	Expired    *bool  `json:"claim_expired"`
	Expires    string `json:"claim_expires_at"`
}

func (claim seatTaskClaim) requireOwner(task, owner string) error {
	if claim.ID != task || claim.Owner != owner || claim.Expired == nil || *claim.Expired || claim.Expires == "" || (claim.Status != "in_progress" && claim.Status != "blocked" && claim.Status != "review") {
		return &client.Error{Code: "conflict", Message: "seat resolution requires your live owned task claim; inspect/renew explicitly"}
	}
	return nil
}

func completeSeatRecord(record map[string]string) error {
	for _, key := range []string{"worktree", "treehouse_root", "treehouse_version", "lease_holder"} {
		if record[key] == "" {
			return fmt.Errorf("incomplete task seat record; coordinate recovery")
		}
	}
	return nil
}

func (c *commands) seatResolve(mode string) *cobra.Command {
	short := map[string]string{"ensure": "Acquire or reuse this owned task's isolated seat", "env": "Print verified non-secret exports for an existing task seat", "check": "Check actual cwd and environment against this owned task's seat"}
	cmd := &cobra.Command{Use: mode + " TASK", Short: short[mode], Args: idArgs}
	source, root := "", ""
	cmd.Flags().StringVar(&source, "repo", "", "Primary source repository (default: seat source or current repository)")
	cmd.Flags().StringVar(&root, "root", "", "Explicit pinned Treehouse pool (default: seat root or task record)")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		api, err := client.New(c.cfg)
		if err != nil {
			return err
		}
		defer api.Close()
		record, err := c.ownedSeatRecord(cmd.Context(), api, args[0])
		if err != nil {
			return err
		}
		resolution, err := c.resolveLocalSeat(cmd.Context(), mode, args[0], source, root, record)
		if err != nil {
			return err
		}
		if mode == "ensure" && !reflect.DeepEqual(record, resolution.Binding) {
			body, err := json.Marshal(resolution.Binding)
			if err != nil {
				return err
			}
			_, err = api.JSON(cmd.Context(), http.MethodPost, "tasks/"+args[0]+"/update", nil, map[string]any{"note": seatRecordPrefix + string(body)})
			if err != nil {
				return fmt.Errorf("seat allocated and preserved; task recording failed, retry ensure for the same task: %w", err)
			}
		}
		if c.json {
			return json.NewEncoder(cmd.OutOrStdout()).Encode(resolution)
		}
		if mode == "check" {
			_, err = fmt.Fprintln(cmd.OutOrStdout(), resolution.Binding["worktree"])
			return err
		}
		for _, key := range []string{"AGENT_ID", "AGENTBOARD_HARNESS", "AGENTBOARD_MODEL", "AGENTBOARD_URL", "AGENTBOARD_SEAT_WORKTREE", "AGENTBOARD_SEAT_SOURCE", "AGENTBOARD_SEAT_ROOT", "AGENTBOARD_SEAT_BRIEF"} {
			if _, err = fmt.Fprintf(cmd.OutOrStdout(), "export %s=%s\n", key, seatShellQuote(resolution.Env[key])); err != nil {
				return err
			}
		}
		_, err = fmt.Fprintf(cmd.OutOrStdout(), "cd -- %s\n", seatShellQuote(resolution.Binding["worktree"]))
		return err
	}
	return cmd
}

type seatTaskPage struct {
	Task   seatTaskClaim           `json:"task"`
	Events []struct{ Body string } `json:"events"`
	Next   string                  `json:"next_cursor"`
}

func (c *commands) ownedSeatPage(ctx context.Context, api *client.Client, task, cursor string) (*seatTaskPage, error) {
	raw, err := api.JSON(ctx, http.MethodGet, "tasks/"+task, url.Values{"limit": {"1000"}, "cursor": {cursor}}, nil)
	if err != nil {
		return nil, err
	}
	var page seatTaskPage
	if err = json.Unmarshal(raw, &page); err != nil {
		return nil, fmt.Errorf("unreadable task seat evidence")
	}
	if err = page.Task.requireOwner(task, c.cfg.Actor.ID); err != nil {
		return nil, err
	}
	return &page, nil
}

func (c *commands) ownedSeatRecord(ctx context.Context, api *client.Client, task string) (map[string]string, error) {
	cursor := ""
	seen := map[string]bool{}
	record := map[string]string{}
	recorded := false
	for {
		page, err := c.ownedSeatPage(ctx, api, task, cursor)
		if err != nil {
			return nil, err
		}
		for _, event := range page.Events {
			if strings.HasPrefix(event.Body, seatRecordPrefix) {
				recorded = true
				record = parseSeatRecord(event.Body)
				// History can contain superseded partial legacy records. Validate
				// only the latest record after following every page.
			}
		}
		if page.Next == "" {
			break
		}
		if seen[page.Next] {
			return nil, fmt.Errorf("task seat pagination repeated a cursor")
		}
		seen[page.Next], cursor = true, page.Next
	}
	if recorded {
		if err := completeSeatRecord(record); err != nil {
			return nil, err
		}
	}
	return record, nil
}

func (c *commands) resolveLocalSeat(ctx context.Context, mode, task, source, root string, record map[string]string) (*seatResolution, error) {
	python, err := exec.LookPath("python3")
	if err != nil {
		return nil, fmt.Errorf("seat recovery requires Python 3, Git and pinned Treehouse v3.1.2")
	}
	input, err := json.Marshal(record)
	if err != nil {
		return nil, err
	}
	argv := []string{"-c", agentboard.SeatLauncher, "--resolve", mode, "--task", task}
	if source != "" {
		argv = append(argv, "--repo", source)
	}
	if root != "" {
		argv = append(argv, "--root", root)
	}
	process := exec.CommandContext(ctx, python, argv...)
	process.Stdin = bytes.NewReader(input)
	// Respect CLI identity flags; never place credentials on argv or in output.
	process.Env = os.Environ()
	for key, value := range map[string]string{"AGENT_ID": c.cfg.Actor.ID, "AGENTBOARD_HARNESS": c.cfg.Actor.Harness, "AGENTBOARD_MODEL": c.cfg.Actor.Model, "AGENTBOARD_URL": c.cfg.URL} {
		process.Env = append(process.Env, key+"="+value)
	}
	var stdout, stderr bytes.Buffer
	process.Stdout, process.Stderr = &stdout, &stderr
	if err = process.Run(); err != nil {
		return nil, fmt.Errorf("seat isolation refused: %s", strings.TrimSpace(stderr.String()))
	}
	var resolution seatResolution
	if json.Unmarshal(stdout.Bytes(), &resolution) != nil || resolution.Binding["task_id"] != task || resolution.Binding["lease_holder"] != c.cfg.Actor.ID || resolution.Binding["worktree"] == "" {
		return nil, fmt.Errorf("invalid local seat resolution receipt")
	}
	return &resolution, nil
}

func seatShellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
