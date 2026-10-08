package cli

import (
	"errors"
	"github.com/spf13/cobra"
	"net/http"
)

func (c *commands) availabilityCommands() *cobra.Command {
	group := &cobra.Command{Use: "availability", Short: "Durable captain availability policies"}
	group.AddCommand(&cobra.Command{Use: "list", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		return c.request(cmd, http.MethodGet, "availability", nil, nil)
	}})
	agent, harness, model, state, reason, until := "", "", "", "", "", ""
	revision := int64(0)
	set := &cobra.Command{Use: "set", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		if state == "" {
			return errors.New("--state is required")
		}
		data := map[string]any{"state": state}
		for k, v := range map[string]string{"agent_id": agent, "harness": harness, "model_pattern": model, "reason": reason, "until": until} {
			if v != "" {
				data[k] = v
			}
		}
		if revision != 0 {
			data["revision"] = revision
		}
		return c.request(cmd, http.MethodPost, "availability", nil, data)
	}}
	set.Flags().StringVar(&agent, "agent-id", "", "Exact agent override")
	set.Flags().StringVar(&harness, "selector-harness", "", "Harness default selector")
	set.Flags().StringVar(&model, "model-pattern", "", "Exact model or trailing wildcard")
	set.Flags().StringVar(&state, "state", "", "active, reserved or out_of_service")
	set.Flags().StringVar(&reason, "reason", "", "Required reason for restricted state")
	set.Flags().StringVar(&until, "until", "", "Optional out_of_service RFC3339 deadline")
	set.Flags().Int64Var(&revision, "revision", 0, "Expected policy revision")
	set.Flags().Bool("captain", true, "Use protected AGENTBOARD_CAPTAIN_TOKEN_FILE")
	group.AddCommand(set)
	return group
}
func (c *commands) broadcastOrders() *cobra.Command {
	task, body, harness := "", "", ""
	cmd := &cobra.Command{Use: "broadcast", Short: "Captain task-order broadcast to active agents", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		if task == "" || body == "" {
			return errors.New("--task and --body are required")
		}
		data := map[string]any{"task": task, "body": body}
		if harness != "" {
			data["harness"] = harness
		}
		return c.request(cmd, http.MethodPost, "messages/task-orders", nil, data)
	}}
	cmd.Flags().StringVar(&task, "task", "", "Existing task ID")
	cmd.Flags().StringVar(&body, "body", "", "Task order body")
	cmd.Flags().StringVar(&harness, "selector-harness", "", "Optional recipient harness filter")
	cmd.Flags().Bool("captain", true, "Use protected AGENTBOARD_CAPTAIN_TOKEN_FILE")
	return cmd
}
