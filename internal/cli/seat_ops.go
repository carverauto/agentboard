package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/seatops"
	"github.com/spf13/cobra"
)

const seatOpsTreehouseVersion = "3.1.2"

func (c *commands) seatNudge() *cobra.Command {
	cmd := &cobra.Command{Use: "nudge", Args: cobra.NoArgs,
		Short: "Prompt idle Herdr seats that have board work to run their check-in (dry run unless --apply)",
		Long: `Nudge maps each Herdr agent pane named after a board agent ID to that seat,
reads the seat's owned tasks, unread messages and availability, and prompts an
idle seat with a reason to run its agentboard check-in. A seat parked on a
captain/coordinator decision is only told about new messages. Before sending it
re-reads the pane and refuses if the native session, agent kind or Herdr state
changed. It never writes to the board.

Name a seat's pane once from inside it:
  herdr agent rename "$HERDR_PANE_ID" "$AGENT_ID"

Kill switch: create the configured kill_switch file (default
~/.config/agentboard/seat/off).`}
	apply, configPath := false, ""
	cmd.Flags().BoolVar(&apply, "apply", false, "Send prompts and save state; without it nothing changes")
	cmd.Flags().StringVar(&configPath, "config", seatops.DefaultConfigPath(), "Optional seat operations config")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		return c.seatOps(cmd, configPath, func(ctx context.Context, board seatops.Board, cfg seatops.Config) (any, error) {
			return seatops.Nudge(ctx, board, seatops.HerdrCLI{Bin: os.Getenv("AGENTBOARD_HERDR_BIN")}, cfg, time.Now().UTC(), apply)
		})
	}
	return cmd
}

func (c *commands) seatReap() *cobra.Command {
	cmd := &cobra.Command{Use: "reap", Args: cobra.NoArgs,
		Short: "Close finished seat panes and return their landed leases (dry run unless --apply)",
		Long: `Reap closes a named Herdr seat pane only when the seat has idled past
reap_after, owns no open task, has no unread message and its checkout has
landed (clean tree, HEAD on a remote branch or origin/main). With
treehouse_roots configured it also returns Treehouse leases whose holder has no
live session, no open task and landed work. It never releases claims or retires
identities: expired claims and finished identities are reported for the captain.`}
	apply, configPath := false, ""
	cmd.Flags().BoolVar(&apply, "apply", false, "Close panes, return leases and save state; without it nothing changes")
	cmd.Flags().StringVar(&configPath, "config", seatops.DefaultConfigPath(), "Optional seat operations config")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		return c.seatOps(cmd, configPath, func(ctx context.Context, board seatops.Board, cfg seatops.Config) (any, error) {
			var leases seatops.Leases
			if len(cfg.TreehouseRoots) > 0 {
				binary, err := seatTreehouseBinary(seatOpsTreehouseVersion)
				if err != nil {
					return nil, err
				}
				leases = treehouseLeases{binary: binary}
			}
			return seatops.Reap(ctx, board, seatops.HerdrCLI{Bin: os.Getenv("AGENTBOARD_HERDR_BIN")}, leases, cfg, time.Now().UTC(), apply)
		})
	}
	return cmd
}

func (c *commands) seatSpawn() *cobra.Command {
	cmd := &cobra.Command{Use: "spawn", Args: cobra.NoArgs,
		Short: "Open a new Herdr tab that launches one seat from the host harness allowlist (dry run unless --apply)",
		Long: `Spawn opens a new Herdr tab labelled with the seat's agent ID and runs
scripts/launch-seat there, which leases a Treehouse v3 worktree, writes the
STOP brief and starts the harness in that worktree. The harness argv, model,
launcher, source checkout and pool come only from the host-local allowlist
(default ~/.config/agentboard/fleet/harnesses.json); nothing comes from the
board. Spawn never types into an existing pane and refuses when a pane or tab
already carries the agent ID. It never writes to the board.`}
	opts := seatops.SpawnOptions{}
	apply, dryRun, configPath := false, false, seatops.DefaultSpawnConfigPath()
	cmd.Flags().StringVar(&opts.Task, "task", "", "Board task the seat is started for")
	cmd.Flags().StringVar(&opts.Agent, "agent", "", "Agent ID of the new seat (tab label and pane name)")
	cmd.Flags().StringVar(&opts.Harness, "harness", "", "Allowlisted harness name")
	cmd.Flags().StringVar(&opts.Brief, "brief", "", "Brief file (default: a generated check-in brief)")
	cmd.Flags().StringVar(&opts.Repo, "repo", "", "Source checkout (default: allowlist repo)")
	cmd.Flags().StringVar(&opts.Root, "root", "", "Treehouse v3 pool root (default: allowlist root)")
	cmd.Flags().StringVar(&configPath, "config", configPath, "Absolute path of the host-local harness allowlist")
	cmd.Flags().BoolVar(&apply, "apply", false, "Open the tab and start the seat; without it nothing changes")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Only report what would run (the default)")
	for _, name := range []string{"task", "agent", "harness"} {
		_ = cmd.MarkFlagRequired(name)
	}
	cmd.MarkFlagsMutuallyExclusive("apply", "dry-run")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		cfg, err := seatops.LoadSpawnConfig(configPath)
		if err != nil {
			return err
		}
		opts.BoardURL = ""
		if os.Getenv("AGENTBOARD_URL") != "" || cmd.Root().PersistentFlags().Changed("url") {
			opts.BoardURL = c.cfg.URL
		}
		plan, err := seatops.PlanSpawn(cfg, opts)
		if err != nil {
			return err
		}
		report, err := seatops.Spawn(cmd.Context(), seatops.HerdrCLI{Bin: os.Getenv("AGENTBOARD_HERDR_BIN")}, plan, apply)
		if report.Spawned != nil || err == nil {
			if encodeErr := json.NewEncoder(cmd.OutOrStdout()).Encode(report); encodeErr != nil {
				return encodeErr
			}
		}
		return err
	}
	return cmd
}

func (c *commands) seatOps(cmd *cobra.Command, configPath string, run func(context.Context, seatops.Board, seatops.Config) (any, error)) error {
	cfg, err := seatops.LoadConfig(configPath)
	if err != nil {
		return err
	}
	api, err := client.New(c.cfg)
	if err != nil {
		return err
	}
	defer api.Close()
	report, err := run(cmd.Context(), apiBoard{api: api, stale: c.staleAfter(cmd)}, cfg)
	if errors.Is(err, seatops.ErrLocked) {
		fmt.Fprintln(cmd.ErrOrStderr(), "skip: "+err.Error())
		return nil
	}
	if err != nil {
		return err
	}
	return writeSeatReport(cmd.OutOrStdout(), report, c.json)
}

func writeSeatReport(out io.Writer, report any, asJSON bool) error {
	if asJSON {
		return json.NewEncoder(out).Encode(report)
	}
	switch r := report.(type) {
	case seatops.NudgeReport:
		for _, d := range r.Decisions {
			fmt.Fprintf(out, "%-8s %s %s %s %s\n", d.Action, d.Agent, d.Pane, d.State, d.Reason)
			if d.Prompt != "" && (d.Action == "nudge" || d.Action == "nudged") {
				fmt.Fprintf(out, "         prompt: %s\n", d.Prompt)
			}
		}
		for _, s := range r.Skipped {
			fmt.Fprintf(out, "skip     %s %s %s\n", s.Agent, s.Pane, s.Reason)
		}
		if r.DryRun {
			fmt.Fprintln(out, "dry run: nothing sent; pass --apply to nudge")
		}
	case seatops.ReapReport:
		for _, a := range r.Actions {
			verb := "would"
			switch {
			case a.Kind == "expired_claim" || a.Kind == "retire_candidate":
				verb = "report"
			case a.Done:
				verb = "done"
			case !r.DryRun:
				verb = "failed"
			}
			fmt.Fprintf(out, "%-6s %-16s %s%s%s%s %s\n", verb, a.Kind, a.Agent, prefixed(" pane=", a.Pane), prefixed(" task=", a.Task), prefixed(" path=", a.Path), a.Reason)
		}
		for _, k := range r.Kept {
			fmt.Fprintf(out, "keep   %s %s %s\n", k.Agent, k.Pane, k.Reason)
		}
		if r.DryRun {
			fmt.Fprintln(out, "dry run: nothing closed or returned; pass --apply to reap")
		}
	}
	return nil
}

func prefixed(prefix, value string) string {
	if value == "" {
		return ""
	}
	return prefix + value
}

// apiBoard is the read-only board view over the HTTP API, paging every list.
type apiBoard struct {
	api   *client.Client
	stale string
}

func (b apiBoard) pages(ctx context.Context, resource string, query url.Values, each func(json.RawMessage) (*string, error)) error {
	query.Set("limit", "1000")
	for {
		raw, err := b.api.JSON(ctx, http.MethodGet, resource, query, nil)
		if err != nil {
			return err
		}
		next, err := each(raw)
		if err != nil {
			return err
		}
		if next == nil || *next == "" {
			return nil
		}
		query.Set("cursor", *next)
	}
}

func (b apiBoard) Agents(ctx context.Context) ([]seatops.BoardAgent, error) {
	var all []seatops.BoardAgent
	query := url.Values{}
	if b.stale != "" {
		query.Set("stale_after", b.stale)
	}
	err := b.pages(ctx, "agents", query, func(raw json.RawMessage) (*string, error) {
		var page struct {
			Agents     []seatops.BoardAgent `json:"agents"`
			NextCursor *string              `json:"next_cursor"`
		}
		err := json.Unmarshal(raw, &page)
		all = append(all, page.Agents...)
		return page.NextCursor, err
	})
	return all, err
}

func (b apiBoard) OwnedTasks(ctx context.Context, agentID string) ([]seatops.Task, error) {
	var owned []seatops.Task
	err := b.pages(ctx, "tasks", url.Values{"owner": {agentID}}, func(raw json.RawMessage) (*string, error) {
		var page struct {
			Tasks      []seatops.Task `json:"tasks"`
			NextCursor *string        `json:"next_cursor"`
		}
		err := json.Unmarshal(raw, &page)
		for _, t := range page.Tasks {
			if t.AssigneeID == agentID && seatops.OpenStatuses[t.Status] {
				owned = append(owned, t)
			}
		}
		return page.NextCursor, err
	})
	return owned, err
}

func (b apiBoard) Unread(ctx context.Context, agentID string) ([]seatops.Message, error) {
	var unread []seatops.Message
	err := b.pages(ctx, "messages", url.Values{"to": {agentID}, "unread": {"true"}}, func(raw json.RawMessage) (*string, error) {
		var page struct {
			Messages []struct {
				seatops.Message
				ReadAt *time.Time `json:"read_at"`
			} `json:"messages"`
			NextCursor *string `json:"next_cursor"`
		}
		err := json.Unmarshal(raw, &page)
		for _, m := range page.Messages {
			if m.ReadAt == nil {
				unread = append(unread, m.Message)
			}
		}
		return page.NextCursor, err
	})
	return unread, err
}

func (b apiBoard) LastBody(ctx context.Context, taskID string) (string, time.Time, error) {
	var body string
	var at time.Time
	err := b.pages(ctx, "tasks/"+taskID, url.Values{}, func(raw json.RawMessage) (*string, error) {
		var page struct {
			Events []struct {
				Body      string    `json:"body"`
				CreatedAt time.Time `json:"created_at"`
			} `json:"events"`
			NextCursor *string `json:"next_cursor"`
		}
		err := json.Unmarshal(raw, &page)
		for _, e := range page.Events {
			if e.Body != "" && !e.CreatedAt.Before(at) {
				body, at = e.Body, e.CreatedAt
			}
		}
		return page.NextCursor, err
	})
	return body, at, err
}

// treehouseLeases lists and returns leases with the pinned Treehouse binary.
type treehouseLeases struct{ binary string }

func (t treehouseLeases) List(ctx context.Context, root string) ([]seatops.Lease, error) {
	out, err := exec.CommandContext(ctx, t.binary, "status", "--root", root, "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("treehouse status: %w", err)
	}
	var all []struct {
		seatops.Lease
		Status string `json:"status"`
	}
	if err := json.Unmarshal(out, &all); err != nil {
		return nil, fmt.Errorf("treehouse status: %w", err)
	}
	var leased []seatops.Lease
	for _, entry := range all {
		if entry.Status == "leased" {
			leased = append(leased, entry.Lease)
		}
	}
	return leased, nil
}

func (t treehouseLeases) Return(ctx context.Context, lease seatops.Lease) error {
	out, err := exec.CommandContext(ctx, t.binary, "return", lease.Path, "--if-lease-holder", lease.Holder, "--root", lease.Root).CombinedOutput()
	if err != nil {
		return fmt.Errorf("treehouse return: %w: %s", err, string(out))
	}
	return nil
}

// nameHerdrPane names the calling Herdr pane after the agent ID so seat nudge
// and reap can find it. It is best effort: outside Herdr it does nothing, and a
// failure only warns because registration itself already succeeded.
func nameHerdrPane(cmd *cobra.Command, agentID string) {
	pane := os.Getenv("HERDR_PANE_ID")
	if pane == "" || agentID == "" {
		return
	}
	bin := os.Getenv("AGENTBOARD_HERDR_BIN")
	if bin == "" {
		bin = "herdr"
	}
	ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, bin, "agent", "rename", pane, agentID).CombinedOutput(); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: could not name Herdr pane %s %q: %v %s\n", pane, agentID, err, strings.TrimSpace(string(out)))
	}
}
