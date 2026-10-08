package cli

import (
	"errors"
	"net/http"
	"net/url"
	"strconv"

	"github.com/spf13/cobra"
)

func (c *commands) heartbeat() *cobra.Command {
	status, task, backend := "", "", ""
	cmd := &cobra.Command{Use: "heartbeat", Short: "Report busy/idle and owned current task without renewing a lease", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&status, "status", "", "busy or idle (required)")
	cmd.Flags().StringVar(&task, "task", "", "Owned current task; omitted clears it")
	cmd.Flags().StringVar(&backend, "backend", "", "Optional current backend")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if status != "busy" && status != "idle" {
			return errors.New("--status must be busy or idle")
		}
		data := map[string]any{"status": status}
		if task != "" {
			data["task"] = task
		}
		if backend != "" {
			data["backend"] = backend
		}
		return c.request(cmd, http.MethodPost, "agents/"+c.cfg.Actor.ID+"/heartbeat", nil, data)
	}
	return cmd
}
func (c *commands) messages() *cobra.Command {
	group := &cobra.Command{Use: "msg", Short: "Durable peer inbox and shared task comments"}
	to, task, body, kind := "", "", "", "note"
	send := &cobra.Command{Use: "send", Short: "Send to a peer and/or task thread", Args: cobra.NoArgs}
	send.Flags().StringVar(&kind, "kind", kind, "note or task_order (active named recipient)")
	send.Flags().StringVar(&to, "to", "", "Registered recipient ID")
	send.Flags().StringVar(&task, "task", "", "Task thread/context")
	send.Flags().StringVar(&body, "body", "", "Nonempty message body")
	send.RunE = func(cmd *cobra.Command, args []string) error {
		if body == "" || (to == "" && task == "") {
			return errors.New("--body and a --to or --task destination are required")
		}
		if kind != "note" && kind != "task_order" {
			return errors.New("--kind must be note or task_order")
		}
		data := map[string]any{"body": body}
		if kind != "note" {
			data["kind"] = kind
		}
		if to != "" {
			data["to"] = to
		}
		if task != "" {
			data["task"] = task
		}
		return c.request(cmd, http.MethodPost, "messages", nil, data)
	}
	list := c.list("messages", []string{"to", "task"})
	unread := false
	list.Flags().BoolVar(&unread, "unread", false, "Unread direct messages only")
	read := &cobra.Command{Use: "read ID", Short: "Explicitly acknowledge a direct message as its recipient", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		id, err := strconv.ParseInt(args[0], 10, 64)
		if err != nil || id <= 0 {
			return errors.New("Message ID must be a positive integer")
		}
		return c.request(cmd, http.MethodPost, "messages/"+strconv.FormatInt(id, 10)+"/read", nil, map[string]any{})
	}}
	group.AddCommand(c.broadcastOrders(), send, list, read, c.watchCommand("messages", []string{"to", "task"}))
	return group
}

func messageQuery(cmd *cobra.Command, q url.Values) {
	if flag := cmd.Flags().Lookup("unread"); flag != nil {
		value, _ := cmd.Flags().GetBool("unread")
		if value {
			q.Set("unread", "true")
		}
	}
}
