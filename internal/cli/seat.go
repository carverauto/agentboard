package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/spf13/cobra"
)

const seatRecordPrefix = "agentboard-seat "

func (c *commands) seat() *cobra.Command {
	group := &cobra.Command{Use: "seat", Short: "Leased Treehouse seat slots"}
	group.AddCommand(c.seatReturn())
	return group
}

func (c *commands) seatReturn() *cobra.Command {
	cmd := &cobra.Command{Use: "return TASK", Short: "Gated return of the task's recorded Treehouse slot", Args: idArgs}
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		return c.seatReturnTask(cmd.Context(), args[0])
	}
	return cmd
}

func (c *commands) seatReturnTask(ctx context.Context, task string) error {
	if err := c.cfg.Actor.Validate(); err != nil {
		return err
	}
	api, err := client.New(c.cfg)
	if err != nil {
		return err
	}
	defer api.Close()
	cursor := ""
	var status string
	record := ""
	for {
		page := url.Values{}
		page.Set("limit", "1000")
		if cursor != "" {
			page.Set("cursor", cursor)
		}
		raw, err := api.JSON(ctx, http.MethodGet, "tasks/"+task, page, nil)
		if err != nil {
			return err
		}
		var show struct {
			Task struct {
				Status string `json:"status"`
			} `json:"task"`
			Events []struct {
				Body string `json:"body"`
			} `json:"events"`
			NextCursor *string `json:"next_cursor"`
		}
		if err := json.Unmarshal(raw, &show); err != nil {
			return err
		}
		status = show.Task.Status
		for _, event := range show.Events {
			if strings.HasPrefix(event.Body, seatRecordPrefix) {
				record = event.Body
			}
		}
		if show.NextCursor == nil || *show.NextCursor == "" {
			break
		}
		cursor = *show.NextCursor
	}
	if status != "done" && status != "cancelled" {
		return fmt.Errorf("refuses: task %s is %q, not done/cancelled", task, status)
	}
	fields := parseSeatRecord(record)
	worktree, version, root, holder := fields["worktree"], fields["treehouse_version"], fields["treehouse_root"], fields["lease_holder"]
	if worktree == "" || version == "" || root == "" || holder == "" {
		return fmt.Errorf("refuses: task %s has no complete slot record", task)
	}
	if holder != c.cfg.Actor.ID {
		return fmt.Errorf("refuses: slot lease holder is %q", holder)
	}
	info, err := os.Stat(worktree)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("refuses: slot path %s is missing on this host", worktree)
	}
	if reason := seatLanded(worktree); reason != "" {
		return fmt.Errorf("refuses: landed gate: %s", reason)
	}
	binary, err := seatTreehouseBinary(version)
	if err != nil {
		return err
	}
	out, err := exec.Command(binary, "return", worktree, "--if-lease-holder", holder, "--root", root).CombinedOutput()
	if err != nil {
		return fmt.Errorf("treehouse return failed: %s: %s", strings.TrimSpace(string(out)), err)
	}
	fmt.Printf("Returned Treehouse %s lease at %s after task %s landed.\n", version, worktree, task)
	return nil
}

func parseSeatRecord(record string) map[string]string {
	fields := map[string]string{}
	body := strings.TrimPrefix(record, seatRecordPrefix)
	body = strings.TrimSpace(body)
	if strings.HasPrefix(body, "{") {
		var decoded map[string]string
		if err := json.Unmarshal([]byte(body), &decoded); err == nil {
			for key, value := range decoded {
				fields[key] = value
			}
			return fields
		}
	}
	for _, part := range strings.Fields(record) {
		key, value, ok := strings.Cut(part, "=")
		if ok {
			fields[key] = value
		}
	}
	return fields
}

func seatGit(worktree string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = worktree
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// seatLanded is the Firstmate-style landed gate: clean tree, and HEAD
// reachable from a remote ref or the base. Empty means landed.
func seatLanded(worktree string) string {
	if dirty, err := seatGit(worktree, "status", "--porcelain"); err != nil || dirty != "" {
		if err != nil {
			return "cannot read worktree status"
		}
		return "uncommitted changes"
	}
	head, err := seatGit(worktree, "rev-parse", "HEAD")
	if err != nil || head == "" {
		return "cannot read HEAD"
	}
	if remotes, err := seatGit(worktree, "branch", "-r", "--contains", head); err == nil && remotes != "" {
		return ""
	}
	for _, base := range []string{"origin/main", "main"} {
		cmd := exec.Command("git", "merge-base", "--is-ancestor", head, base)
		cmd.Dir = worktree
		if cmd.Run() == nil {
			return ""
		}
	}
	return "HEAD is not reachable from any remote branch or base"
}

func seatTreehouseBinary(version string) (string, error) {
	candidates := []string{}
	if custom := os.Getenv("AGENTBOARD_TREEHOUSE_BIN"); custom != "" {
		candidates = append(candidates, custom)
	}
	candidates = append(candidates, filepath.Join(os.Getenv("HOME"), ".local/share/agentboard/tools/treehouse/v"+version, "treehouse"))
	if path, err := exec.LookPath("treehouse"); err == nil {
		candidates = append(candidates, path)
	}
	for _, binary := range candidates {
		out, err := exec.Command(binary, "--version").Output()
		if err != nil {
			continue
		}
		if strings.TrimSpace(string(out)) == "v"+version {
			return binary, nil
		}
	}
	return "", fmt.Errorf("no Treehouse v%s binary found; run scripts/install-treehouse", version)
}
