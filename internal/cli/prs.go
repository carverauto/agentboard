package cli

import (
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
	group.AddCommand(list, show)
	return group
}
