package cli

import (
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/spf13/cobra"
)

func (c *commands) heartbeat() *cobra.Command {
	status, task, backend := "", "", ""
	var every time.Duration
	cmd := &cobra.Command{Use: "heartbeat", Short: "Report busy/idle and owned current task without renewing a lease", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&status, "status", "", "busy or idle (required)")
	cmd.Flags().StringVar(&task, "task", "", "Owned current task; omitted clears it")
	cmd.Flags().StringVar(&backend, "backend", "", "Optional current backend")
	cmd.Flags().DurationVar(&every, "every", 0, "Repeat the heartbeat on this cadence until interrupted (e.g. 5m)")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if status != "busy" && status != "idle" {
			return errors.New("--status must be busy or idle")
		}
		if every < 0 {
			return errors.New("--every must be a positive duration")
		}
		data := map[string]any{"status": status}
		if task != "" {
			data["task"] = task
		}
		if backend != "" {
			data["backend"] = backend
		}
		beat := func() error {
			return c.request(cmd, http.MethodPost, "agents/"+c.cfg.Actor.ID+"/heartbeat", nil, data)
		}
		if err := beat(); err != nil {
			return err
		}
		if every == 0 {
			return nil
		}
		ticker := time.NewTicker(every)
		defer ticker.Stop()
		for {
			select {
			case <-cmd.Context().Done():
				return nil
			case <-ticker.C:
				if err := beat(); err != nil {
					return err
				}
			}
		}
	}
	return cmd
}
func (c *commands) messages() *cobra.Command {
	group := &cobra.Command{Use: "msg", Short: "Durable peer inbox and shared task comments"}
	to, task, body, kind, triage := "", "", "", "note", ""
	send := &cobra.Command{Use: "send", Short: "Send to a peer and/or task thread", Args: cobra.NoArgs}
	send.Flags().StringVar(&kind, "kind", kind, "note or task_order (active named recipient)")
	send.Flags().StringVar(&to, "to", "", "Registered recipient ID")
	send.Flags().StringVar(&task, "task", "", "Task thread/context")
	send.Flags().StringVar(&body, "body", "", "Nonempty message body")
	send.Flags().StringVar(&triage, "triage", "", "Strict v1 note triage metadata as JSON (up to 4096 bytes)")
	send.RunE = func(cmd *cobra.Command, args []string) error {
		if body == "" || (to == "" && task == "") {
			return errors.New("--body and a --to or --task destination are required")
		}
		if kind != "note" && kind != "task_order" {
			return errors.New("--kind must be note or task_order")
		}
		data := map[string]any{"body": body}
		if cmd.Flags().Changed("triage") {
			if kind != "note" {
				return errors.New("--triage is only supported for --kind note")
			}
			metadata, err := parseMessageTriage(triage)
			if err != nil {
				return err
			}
			data["triage"] = metadata
		}
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
	list.Flags().String("triage-state", "", "Filter recorded, blocked, escalation_pending, or unresolved triage")
	listRun := list.RunE
	list.RunE = func(cmd *cobra.Command, args []string) error {
		if cmd.Flags().Changed("triage-state") {
			state, _ := cmd.Flags().GetString("triage-state")
			switch state {
			case "recorded", "blocked", "escalation_pending", "unresolved":
			default:
				return errors.New("--triage-state must be recorded, blocked, escalation_pending, or unresolved")
			}
			watch, _ := cmd.Flags().GetBool("watch")
			if watch {
				return errors.New("--triage-state is not supported with --watch")
			}
		}
		return listRun(cmd, args)
	}
	show := c.messageRead("show ID", "Show one message without acknowledging it", "")
	triageRead := c.messageRead("triage ID", "Show a message's triage audit without acknowledging it", "/triage")
	read := &cobra.Command{Use: "read ID", Short: "Explicitly acknowledge a direct message as its recipient", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		id, err := strconv.ParseInt(args[0], 10, 64)
		if err != nil || id <= 0 {
			return errors.New("Message ID must be a positive integer")
		}
		return c.request(cmd, http.MethodPost, "messages/"+strconv.FormatInt(id, 10)+"/read", nil, map[string]any{})
	}}
	group.AddCommand(c.broadcastOrders(), send, list, show, triageRead, read, c.watchCommand("messages", []string{"to", "task"}))
	return group
}

func (c *commands) messageRead(use, short, suffix string) *cobra.Command {
	return &cobra.Command{Use: use, Short: short, Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		id, err := strconv.ParseInt(args[0], 10, 64)
		if err != nil || id <= 0 {
			return errors.New("Message ID must be a positive integer")
		}
		return c.request(cmd, http.MethodGet, "messages/"+strconv.FormatInt(id, 10)+suffix, nil, nil)
	}}
}

func messageQuery(cmd *cobra.Command, q url.Values) {
	if flag := cmd.Flags().Lookup("unread"); flag != nil {
		value, _ := cmd.Flags().GetBool("unread")
		if value {
			q.Set("unread", "true")
		}
	}
	if flag := cmd.Flags().Lookup("triage-state"); flag != nil {
		value, _ := cmd.Flags().GetString("triage-state")
		if value != "" {
			q.Set("triage_state", value)
		}
	}
}
