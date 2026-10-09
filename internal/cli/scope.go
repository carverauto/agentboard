package cli

import (
	"errors"
	"net/http"
	"strings"

	"github.com/spf13/cobra"
)

func (c *commands) scopeCommands() *cobra.Command {
	group := &cobra.Command{Use: "scope", Short: "Captain-managed repository and label admission scope"}
	show := &cobra.Command{Use: "show AGENT_ID", Short: "Show managed or unmanaged seat scope", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.request(cmd, http.MethodGet, "agents/"+args[0]+"/scope", nil, nil)
		}}
	repos, requiredLabels, allowedLabels := []string{}, []string{}, []string{}
	revision := int64(0)
	set := &cobra.Command{Use: "set AGENT_ID", Short: "Replace the complete seat scope using its current revision", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !cmd.Flags().Changed("revision") || revision < 0 {
				return errors.New("--revision is required and must be nonnegative (use 0 for unmanaged scope)")
			}
			if len(repos) == 0 {
				return errors.New("at least one explicit owner/repo --repo is required")
			}
			for _, repo := range repos {
				if strings.TrimSpace(repo) == "" {
					return errors.New("--repo must not be empty")
				}
			}
			return c.request(cmd, http.MethodPut, "agents/"+args[0]+"/scope", nil, map[string]any{
				"allowed_repos": repos, "required_labels": requiredLabels,
				"allowed_labels": allowedLabels, "revision": revision,
			})
		}}
	set.Flags().StringArrayVar(&repos, "repo", []string{}, "Explicit owner/repo; repeat for each allowed repository")
	set.Flags().StringArrayVar(&requiredLabels, "required-label", []string{}, "Required task label (all must match); repeat; omit to disable this gate")
	set.Flags().StringArrayVar(&allowedLabels, "allowed-label", []string{}, "Allowed task label (any must match); repeat; omit to disable this gate")
	set.Flags().Int64Var(&revision, "revision", 0, "Expected scope revision (required; 0 creates a managed scope)")
	set.Flags().Bool("captain", true, "Use protected AGENTBOARD_CAPTAIN_TOKEN_FILE capability")
	group.AddCommand(show, set)
	return group
}
