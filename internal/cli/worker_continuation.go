package cli

import (
	"encoding/json"
	"errors"
	"net/http"
	"slices"

	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

var continuationDispositions = []string{"no_new_finding", "provider_outage", "model_outage", "quota_exhausted"}

func workerContinuation(load func() (worker.Config, worker.Binding, error), output func(*cobra.Command, any) error) *cobra.Command {
	var disposition, reason, key string
	command := &cobra.Command{
		Use:   "continuation",
		Short: "Read idle continuation state or record an explicit disposition; never acknowledges",
		Long: "Without --disposition, reads the scoped idle continuation state: eligibility, suppression reason codes, cooldown and limits. " +
			"With --disposition no_new_finding, records that the last turn established nothing worth publishing; reminders stay suppressed until new recorded progress. " +
			"provider_outage, model_outage and quota_exhausted enter a bounded, visible cooldown. --reason and a stable --key are required; " +
			"retrying the same key and content is idempotent. Uses the epoch receipt capability. It never acknowledges a delivery, publishes Context or changes a task.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if disposition == "" && (reason != "" || key != "") {
				return errors.New("--reason and --key require --disposition")
			}
			if disposition != "" && !slices.Contains(continuationDispositions, disposition) {
				return errors.New("--disposition must be no_new_finding, provider_outage, model_outage or quota_exhausted")
			}
			if disposition != "" && (reason == "" || key == "") {
				return errors.New("--disposition requires --reason and a stable --key")
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
			var raw json.RawMessage
			if disposition == "" {
				raw, err = api.Call(cmd.Context(), http.MethodGet, "continuation", nil, nil)
			} else {
				raw, err = api.Call(cmd.Context(), http.MethodPost, "continuation", nil, map[string]any{"disposition": disposition, "reason": reason, "idempotency_key": key})
			}
			if err != nil {
				return err
			}
			return output(cmd, raw)
		},
	}
	command.Flags().StringVar(&disposition, "disposition", "", "no_new_finding, provider_outage, model_outage or quota_exhausted")
	command.Flags().StringVar(&reason, "reason", "", "Bounded explanation recorded with the disposition (at most 512 bytes)")
	command.Flags().StringVar(&key, "key", "", "Stable disposition idempotency key")
	return command
}
