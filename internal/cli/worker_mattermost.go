package cli

import (
	"errors"
	"strings"

	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

func workerMattermostCommands(load func() (worker.Config, worker.Binding, error), output func(*cobra.Command, any) error) []*cobra.Command {
	var id, version string
	read := &cobra.Command{
		Use: "mattermost-read", Short: "Read one exact scoped inbox version; never acknowledge", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			item := worker.InboxItem{ID: id, Version: version}
			if err := item.Validate(); err != nil {
				return err
			}
			cfg, binding, err := load()
			if err != nil {
				return err
			}
			api, err := worker.OpenAPI(cfg, binding, true)
			if err != nil {
				return err
			}
			defer api.Close()
			// The receipt file may have rotated after loading the local binding.
			// Verify that this pinned capability still names that exact session;
			// a subsequent rebind revokes the token before the source operation.
			if _, err := worker.CurrentState(cmd.Context(), api, binding); err != nil {
				return err
			}
			result, err := api.MattermostRead(cmd.Context(), item)
			if err != nil {
				return err
			}
			return output(cmd, result)
		},
	}
	read.Flags().StringVar(&id, "id", "", "Exact inbox UUID from worker check-in (required)")
	read.Flags().StringVar(&version, "version", "", "Exact lowercase SHA-256 version from worker check-in (required)")
	var pairs []string
	ack := &cobra.Command{
		Use: "mattermost-ack", Short: "Explicitly handle exact inbox versions; no task or CI completion", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if len(pairs) < 1 || len(pairs) > 50 {
				return errors.New("supply 1 to 50 --item UUID:VERSION pairs")
			}
			items := make([]worker.InboxItem, 0, len(pairs))
			seen := make(map[string]bool, len(pairs))
			for _, pair := range pairs {
				id, version, ok := strings.Cut(pair, ":")
				item := worker.InboxItem{ID: id, Version: version}
				if !ok || item.Validate() != nil {
					return errors.New("each --item must name an exact inbox UUID:SHA256_VERSION pair")
				}
				canonicalID := strings.ToLower(item.ID)
				if seen[canonicalID] {
					return errors.New("Mattermost acknowledgement requires unique inbox items")
				}
				seen[canonicalID] = true
				items = append(items, item)
			}
			cfg, binding, err := load()
			if err != nil {
				return err
			}
			api, err := worker.OpenAPI(cfg, binding, true)
			if err != nil {
				return err
			}
			defer api.Close()
			// The receipt file may have rotated after loading the local binding.
			// Verify that this pinned capability still names that exact session;
			// a subsequent rebind revokes the token before the source operation.
			if _, err := worker.CurrentState(cmd.Context(), api, binding); err != nil {
				return err
			}
			result, err := api.MattermostAck(cmd.Context(), items)
			if err != nil {
				return err
			}
			return output(cmd, result)
		},
	}
	ack.Flags().StringArrayVar(&pairs, "item", nil, "Exact inbox UUID:VERSION to handle (repeatable, maximum 50)")
	return []*cobra.Command{read, ack}
}
