package cli

import (
	"errors"
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

func (c *commands) chat() *cobra.Command {
	group := &cobra.Command{Use: "chat", Short: "Agent chat through the shared board bot (no Mattermost credentials held)"}
	group.AddCommand(c.chatSend(), c.chatRead(), c.chatReport())
	return group
}

func (c *commands) chatSend() *cobra.Command {
	channel, body, task, kind, rootID, retryKey, iconURL := "", "", "", "", "", "", ""
	cmd := &cobra.Command{Use: "send", Short: "Post to a channel or thread as the calling agent", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&channel, "channel", "", "Channel ID to post to (required)")
	cmd.Flags().StringVar(&body, "body", "", "Message text (required)")
	cmd.Flags().StringVar(&task, "task", "", "Task ID stamped in the header line and props (default general)")
	cmd.Flags().StringVar(&kind, "kind", "", "Post kind: status, decision, handoff, ask-user, note (default note)")
	cmd.Flags().StringVar(&rootID, "root-id", "", "Root post ID to reply in a thread")
	cmd.Flags().StringVar(&retryKey, "retry-key", "", "Client idempotency key; a matching recent post is adopted, never duplicated")
	cmd.Flags().StringVar(&iconURL, "icon-url", "", "Optional per-agent icon URL override")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		if channel == "" || body == "" {
			return errors.New("--channel and --body are required")
		}
		payload := map[string]any{"channel_id": channel, "message": body}
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
		return c.request(cmd, http.MethodPost, "conversations/send", nil, payload)
	}
	return cmd
}

func (c *commands) chatRead() *cobra.Command {
	channel, since := "", ""
	limit := 0
	cmd := &cobra.Command{Use: "read", Short: "Read recent channel posts with own-echo suppression", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&channel, "channel", "", "Channel ID to read (required)")
	cmd.Flags().IntVar(&limit, "limit", 50, "Newest posts to fetch, 1-200")
	cmd.Flags().StringVar(&since, "since", "", "Exclusive cursor: stop at this post ID")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		if channel == "" {
			return errors.New("--channel is required")
		}
		if limit < 1 || limit > 200 {
			return errors.New("--limit must be between 1 and 200")
		}
		query := url.Values{}
		query.Set("channel_id", channel)
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
