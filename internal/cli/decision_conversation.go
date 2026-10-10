package cli

import (
	"errors"
	"net/http"
	"regexp"
	"strings"

	"github.com/spf13/cobra"
)

var (
	conversationUUID    = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	conversationVersion = regexp.MustCompile(`^[0-9a-f]{64}$`)
	conversationChannel = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
)

const decisionConversationAuthority = "The canonical board decision remains authoritative. Conversation replies never answer or apply it. Exact source acknowledgment is separate: use the existing protected worker mattermost-ack command."

func conversationDecisionIDArgs(cmd *cobra.Command, args []string) error {
	if err := cobra.ExactArgs(1)(cmd, args); err != nil {
		return err
	}
	if !conversationUUID.MatchString(args[0]) {
		return errors.New("DECISION_ID must be a canonical lowercase UUID")
	}
	return nil
}

func (c *commands) decisionConversation() *cobra.Command {
	group := &cobra.Command{
		Use:   "conversation",
		Short: "Notify and reply with retained conversation receipts for a board decision",
		Long:  "Notify and reply using an ordinary bearer credential; no captain capability is used.\n\n" + decisionConversationAuthority,
	}
	var channel string
	notify := &cobra.Command{
		Use:   "notify DECISION_ID",
		Short: "Retain a board notice and request a pinned coordinator chat notification",
		Long:  "Retain a board notice and request its pinned coordinator chat notification. The receipt reports the actual submission state, including uncertainty.\n\n" + decisionConversationAuthority,
		Args:  conversationDecisionIDArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !conversationChannel.MatchString(channel) {
				return errors.New("--channel must contain 1–128 ASCII letters, digits, underscores or hyphens")
			}
			return c.request(cmd, http.MethodPost, "decisions/"+args[0]+"/conversation", nil, map[string]any{"channel_id": channel})
		},
	}
	notify.Flags().StringVar(&channel, "channel", "", "Pinned coordinator channel ID (required)")
	show := &cobra.Command{
		Use:   "show DECISION_ID",
		Short: "Read retained conversation receipts without consuming or sending anything",
		Long:  "Read retained conversation receipts without consuming a source or submitting a remote post.\n\n" + decisionConversationAuthority,
		Args:  conversationDecisionIDArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.request(cmd, http.MethodGet, "decisions/"+args[0]+"/conversation", nil, nil)
		},
	}
	var inboxID, version, retryKey, body string
	reply := &cobra.Command{
		Use:   "reply DECISION_ID",
		Short: "Reply to an exact verified source using a stable retry key",
		Long:  "Reply as the configured coordinator participant to an exact verified inbox source. Retain the same retry key and body when retrying; a receipt may remain uncertain.\n\n" + decisionConversationAuthority,
		Args:  conversationDecisionIDArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !conversationUUID.MatchString(inboxID) {
				return errors.New("--inbox-id must be a canonical lowercase UUID")
			}
			if !conversationVersion.MatchString(version) {
				return errors.New("--version must be a lowercase 64-hex SHA-256")
			}
			if !decisionText(retryKey, 128) {
				return errors.New("--retry-key must be nonblank UTF-8, at most 128 bytes, without NUL")
			}
			if !decisionText(body, 16000) {
				return errors.New("--body must be nonblank UTF-8, at most 16000 bytes, without NUL")
			}
			return c.request(cmd, http.MethodPost, "decisions/"+args[0]+"/conversation/replies", nil, map[string]any{
				"inbox_id": inboxID, "version": version, "retry_key": retryKey, "body": body,
			})
		},
	}
	reply.Flags().StringVar(&inboxID, "inbox-id", "", "Exact inbox UUID from protected worker check-in (required)")
	reply.Flags().StringVar(&version, "version", "", "Exact source version SHA-256 (required)")
	reply.Flags().StringVar(&retryKey, "retry-key", "", "Stable reply identity, at most 128 UTF-8 bytes (required)")
	reply.Flags().StringVar(&body, "body", "", "Conversation text, at most 16000 UTF-8 bytes (required)")
	var intentID string
	reconcile := &cobra.Command{
		Use:   "reconcile DECISION_ID",
		Short: "Explicitly reconcile a retained intent without submitting another message",
		Long:  "Explicitly reconcile a retained intent using bounded remote reads. A missing post or incomplete scan may remain uncertain and never authorizes a new submission.\n\n" + decisionConversationAuthority,
		Args:  conversationDecisionIDArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !conversationUUID.MatchString(intentID) {
				return errors.New("--intent-id must be a canonical lowercase UUID")
			}
			return c.request(cmd, http.MethodPost, "decisions/"+args[0]+"/conversation/reconcile", nil, map[string]any{"intent_id": intentID})
		},
	}
	reconcile.Flags().StringVar(&intentID, "intent-id", "", "Retained notification or reply intent UUID (required)")
	group.AddCommand(notify, show, reply, reconcile)
	return group
}

func isDecisionConversationPath(path string) bool {
	parts := strings.Split(path, "/")
	return len(parts) >= 3 && parts[0] == "decisions" && parts[2] == "conversation" &&
		(len(parts) == 3 || len(parts) == 4 && (parts[3] == "replies" || parts[3] == "reconcile"))
}
