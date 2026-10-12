package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"

	"github.com/spf13/cobra"
)

// Headless Mattermost chat through the Agentboard API.
//
// Phase 1 shared-bot model: agents never hold Mattermost credentials and
// never talk to Mattermost directly. The CLI calls the Agentboard API with
// the registered agent identity; the server posts with the ONE shared bot,
// stamping per-agent attribution (header line plus structured props) and
// recording coverage. The server posting seam stays pluggable so phase 2
// per-agent bots swap in transparently.
//
// Every send is spooled server-side before Mattermost sees it. A receipt
// whose state is unresolved (submitting, uncertain, expired) exits 5 after
// printing it: the post may or may not exist, and only `chat resolve`
// (reconcile, retry or abandon) settles it. Re-running the same send with the
// same --retry-key reconciles instead of posting again.

// chatUnresolved reports an unresolved spool receipt through the exit code.
type chatUnresolved struct{ state, msgID string }

func (e *chatUnresolved) Error() string {
	return fmt.Sprintf("send %s is %s; inspect with `agentboard chat status --msg-id %s` and resolve explicitly", e.msgID, e.state, e.msgID)
}
func (e *chatUnresolved) ExitCode() int     { return 5 }
func (e *chatUnresolved) ErrorCode() string { return "send_unresolved" }

// printReceipt prints a send receipt and maps unresolved states to exit 5.
func (c *commands) printReceipt(cmd *cobra.Command, raw json.RawMessage) error {
	if err := c.output(cmd.OutOrStdout(), raw); err != nil {
		return err
	}
	var receipt struct {
		State string `json:"state"`
		MsgID string `json:"msg_id"`
		Send  *struct {
			State string `json:"state"`
			MsgID string `json:"msg_id"`
		} `json:"send"`
	}
	if json.Unmarshal(raw, &receipt) != nil {
		return nil
	}
	if receipt.Send != nil {
		receipt.State, receipt.MsgID = receipt.Send.State, receipt.Send.MsgID
	}
	switch receipt.State {
	case "submitting", "uncertain", "expired":
		return &chatUnresolved{state: receipt.State, msgID: receipt.MsgID}
	}
	return nil
}

func (c *commands) chat() *cobra.Command {
	group := &cobra.Command{Use: "chat", Short: "Agent chat through the shared board bot (no Mattermost credentials held)"}
	group.AddCommand(c.chatSend(), c.chatRead(), c.chatReport(), c.chatStatus(), c.chatSends(), c.chatResolve())
	return group
}

func (c *commands) chatSend() *cobra.Command {
	channel, to, body, task, kind, rootID, retryKey, iconURL := "", "", "", "", "", "", "", ""
	cmd := &cobra.Command{Use: "send", Short: "Post to a channel, thread or peer's private route as the calling agent", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&channel, "channel", "", "Channel ID to post to (or use --to)")
	cmd.Flags().StringVar(&to, "to", "", "Recipient agent ID; posts to its private route (server must enable routes)")
	cmd.Flags().StringVar(&body, "body", "", "Message text (required)")
	cmd.Flags().StringVar(&task, "task", "", "Task ID stamped in the header line and props (default general)")
	cmd.Flags().StringVar(&kind, "kind", "", "Post kind: status, decision, handoff, ask-user, note (default note)")
	cmd.Flags().StringVar(&rootID, "root-id", "", "Root post ID to reply in a thread")
	cmd.Flags().StringVar(&retryKey, "retry-key", "", "Idempotency key: a repeat reconciles the spooled send or adopts its post instead of posting again")
	cmd.Flags().StringVar(&iconURL, "icon-url", "", "Optional per-agent icon URL override")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		if (channel == "") == (to == "") || body == "" {
			return errors.New("--body and exactly one of --channel or --to are required")
		}
		payload := map[string]any{"body": body}
		if channel != "" {
			payload["channel_id"] = channel
		} else {
			payload["to"] = to
		}
		if task != "" {
			payload["task_id"] = task
		}
		if kind != "" {
			payload["kind"] = kind
		}
		if rootID != "" {
			payload["root_id"] = rootID
		}
		if retryKey != "" {
			payload["retry_key"] = retryKey
		}
		if iconURL != "" {
			payload["icon_url"] = iconURL
		}
		raw, err := c.call(cmd, http.MethodPost, "conversations/send", nil, payload)
		if err != nil {
			return err
		}
		return c.printReceipt(cmd, raw)
	}
	return cmd
}

func (c *commands) chatRead() *cobra.Command {
	channel, since := "", ""
	limit := 0
	inbox := false
	cmd := &cobra.Command{Use: "read", Short: "Read recent channel posts with own-echo suppression", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&channel, "channel", "", "Channel ID to read (or use --inbox)")
	cmd.Flags().BoolVar(&inbox, "inbox", false, "Read your own private recipient route")
	cmd.Flags().IntVar(&limit, "limit", 50, "Newest posts to fetch, 1-200")
	cmd.Flags().StringVar(&since, "since", "", "Exclusive cursor: stop at this post ID")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		if (channel == "") == !inbox {
			return errors.New("exactly one of --channel or --inbox is required")
		}
		if limit < 1 || limit > 200 {
			return errors.New("--limit must be between 1 and 200")
		}
		query := url.Values{}
		if inbox {
			query.Set("inbox", "true")
		} else {
			query.Set("channel_id", channel)
		}
		query.Set("limit", strconv.Itoa(limit))
		if since != "" {
			query.Set("since", since)
		}
		return c.request(cmd, http.MethodGet, "conversations/reads", query, nil)
	}
	return cmd
}

func (c *commands) chatReport() *cobra.Command {
	channel, lastPostID, reason := "", "", ""
	version := 0
	caughtUp := false
	cmd := &cobra.Command{Use: "report", Short: "Record an explicit coverage receipt for a channel", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&channel, "channel", "", "Channel ID (required)")
	cmd.Flags().StringVar(&lastPostID, "last-post-id", "", "Newest post observed (required)")
	cmd.Flags().IntVar(&version, "last-version", 0, "Post version observed")
	cmd.Flags().BoolVar(&caughtUp, "caught-up", false, "Mark catch-up complete")
	cmd.Flags().StringVar(&reason, "incomplete-reason", "", "Explicit reason when catch-up is incomplete")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if channel == "" || lastPostID == "" {
			return errors.New("--channel and --last-post-id are required")
		}
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		payload := map[string]any{
			"last_post_id": lastPostID,
			"last_version": version,
			"caught_up":    caughtUp,
		}
		if !caughtUp && reason != "" {
			payload["incomplete_reason"] = reason
		}
		return c.request(cmd, http.MethodPost, "conversations/coverage/"+c.cfg.Actor.ID+"/"+channel, nil, payload)
	}
	return cmd
}

func (c *commands) chatStatus() *cobra.Command {
	msgID := ""
	cmd := &cobra.Command{Use: "status", Short: "Show one of your spooled send receipts (metadata only)", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&msgID, "msg-id", "", "msg_id from a send receipt (required)")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		if msgID == "" {
			return errors.New("--msg-id is required")
		}
		raw, err := c.call(cmd, http.MethodGet, "conversations/sends/"+url.PathEscape(msgID), nil, nil)
		if err != nil {
			return err
		}
		return c.printReceipt(cmd, raw)
	}
	return cmd
}

func (c *commands) chatSends() *cobra.Command {
	state := ""
	cmd := &cobra.Command{Use: "sends", Short: "List your unresolved or failed spooled sends (metadata only)", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&state, "state", "", "Filter: submitting, sent, uncertain, failed, abandoned or expired")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		query := url.Values{}
		if state != "" {
			query.Set("state", state)
		}
		return c.request(cmd, http.MethodGet, "conversations/sends", query, nil)
	}
	return cmd
}

func (c *commands) chatResolve() *cobra.Command {
	msgID, action := "", ""
	cmd := &cobra.Command{Use: "resolve", Short: "Settle an unresolved send: reconcile, retry (records a possible duplicate) or abandon", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&msgID, "msg-id", "", "msg_id from a send receipt (required)")
	cmd.Flags().StringVar(&action, "action", "", "reconcile, retry or abandon (required)")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		if msgID == "" {
			return errors.New("--msg-id is required")
		}
		switch action {
		case "reconcile", "retry", "abandon":
		default:
			return errors.New("--action must be reconcile, retry or abandon")
		}
		raw, err := c.call(cmd, http.MethodPost, "conversations/sends/"+url.PathEscape(msgID)+"/resolve", nil, map[string]any{"action": action})
		if err != nil {
			return err
		}
		return c.printReceipt(cmd, raw)
	}
	return cmd
}
