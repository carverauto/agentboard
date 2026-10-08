package cli

import (
	"errors"
	"github.com/carverauto/agentboard/internal/config"
	"net/http"
	"net/url"

	"github.com/spf13/cobra"
)

// PRs are API projections. The client never contacts GitHub or PostgreSQL.
func (c *commands) prs() *cobra.Command {
	group := &cobra.Command{Use: "pr", Short: "Read tracked pull requests, CI and merge conflicts"}
	var cursor string
	var terminal bool
	list := &cobra.Command{Use: "list", Short: "List tracked PRs with freshness and rebase follow-ups", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		query := url.Values{}
		if cursor != "" {
			query.Set("cursor", cursor)
		}
		if terminal {
			query.Set("show_terminal", "true")
		}
		return c.request(cmd, http.MethodGet, "prs", query, nil)
	}}
	list.Flags().StringVar(&cursor, "cursor", "", "Continue after a canonical PR ID")
	list.Flags().BoolVar(&terminal, "show-terminal", false, "Include merged and closed PRs")
	show := &cobra.Command{Use: "show ID", Short: "Show a canonical PR and its observation history", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		return c.request(cmd, http.MethodGet, "prs/"+url.PathEscape(args[0]), nil, nil)
	}}
	var task string
	decision := &cobra.Command{Use: "duplicate-decision ID", Short: "As live owner, request captain disposition of a possible duplicate", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		if !config.ValidID(task) {
			return errors.New("--task requires the duplicate PR's owned linked card")
		}
		return c.request(cmd, http.MethodPost, "prs/"+url.PathEscape(args[0])+"/duplicate-decision", nil, map[string]any{"task": task})
	}}
	decision.Flags().StringVar(&task, "task", "", "Owned card linked to this duplicate PR (required)")
	group.AddCommand(list, show, decision)
	return group
}
