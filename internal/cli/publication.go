package cli

import (
	"errors"
	"net/http"

	"github.com/carverauto/agentboard/internal/config"
	"github.com/spf13/cobra"
)

func (c *commands) publications() *cobra.Command {
	group := &cobra.Command{Use: "publication", Short: "Bind a head branch to an owned task through the API"}
	var repo, headRepo, branch string
	bind := &cobra.Command{Use: "bind TASK", Short: "Retain exact branch/card attribution (not a write grant)", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		if !config.ValidID(args[0]) || repo == "" || branch == "" {
			return errors.New("publication bind needs TASK, --repo and --branch")
		}
		head := headRepo
		if head == "" {
			head = repo
		}
		return c.request(cmd, http.MethodPost, "publications/bind", nil, map[string]any{
			"task": args[0], "repo": repo, "head_repo": head, "branch": branch,
		})
	}}
	bind.Flags().StringVar(&repo, "repo", "", "Target repository owner/name (required)")
	bind.Flags().StringVar(&headRepo, "head-repo", "", "Head repository owner/name (defaults to --repo)")
	bind.Flags().StringVar(&branch, "branch", "", "Exact short head branch (required)")
	group.AddCommand(bind)
	return group
}
