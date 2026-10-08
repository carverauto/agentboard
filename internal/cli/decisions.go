package cli

import (
	"errors"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/carverauto/agentboard/internal/config"
	"github.com/spf13/cobra"
)

var decisionUUID = regexp.MustCompile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

func decisionIDArgs(cmd *cobra.Command, args []string) error {
	if err := cobra.ExactArgs(1)(cmd, args); err != nil {
		return err
	}
	if !decisionUUID.MatchString(args[0]) {
		return errors.New("Decision/wake ID must be a UUID")
	}
	return nil
}

func (c *commands) decisions() *cobra.Command {
	group := &cobra.Command{Use: "decision", Short: "Durable captain questions, answers and explicit claim recovery"}
	var task, kind, gate, question, findingsFile, retryKey string
	var options []string
	var newRequest bool
	var expires int
	request := &cobra.Command{Use: "request [TASK]", Short: "File any captain question on your owned task", Args: cobra.MaximumNArgs(1)}
	request.Flags().StringVar(&task, "task", "", "Owned task; must agree with positional TASK")
	request.Flags().StringVar(&kind, "kind", "approval", "approval, merge, policy, credential, scope, ask_user_gate, blocked_decision or other")
	request.Flags().StringVar(&gate, "gate", "", "Stable explicit gate (required for ask_user_gate)")
	request.Flags().StringVar(&question, "question", "", "Verbatim bounded question (required)")
	request.Flags().StringVar(&findingsFile, "findings-file", "", "Regular bounded UTF-8 findings file (required for ask_user_gate)")
	request.Flags().StringArrayVar(&options, "option", nil, "Optional choice; repeat for each option")
	request.Flags().BoolVar(&newRequest, "new", false, "Deliberate re-ask after terminal disposition; requires --request-key")
	request.Flags().StringVar(&retryKey, "request-key", "", "Stable retry identity for --new")
	request.Flags().IntVar(&expires, "expires-in", 0, "Optional non-gate expiry in seconds (60–2592000); cleanup defaults off")
	request.RunE = func(cmd *cobra.Command, args []string) error {
		if len(args) == 1 {
			if task != "" && task != args[0] {
				return errors.New("TASK and --task must agree")
			}
			task = args[0]
		}
		// Preserve the historical explicit gate+findings form's default kind.
		if !cmd.Flags().Changed("kind") && gate != "" && findingsFile != "" {
			kind = "ask_user_gate"
		}
		if !config.ValidID(task) || !decisionText(question, 8192) {
			return errors.New("A valid TASK and bounded UTF-8 --question are required")
		}
		switch kind {
		case "approval", "merge", "policy", "credential", "scope", "ask_user_gate", "blocked_decision", "other":
		default:
			return errors.New("Unknown decision kind")
		}
		if gate != "" && !decisionText(gate, 512) {
			return errors.New("--gate must be bounded UTF-8")
		}
		if kind == "ask_user_gate" && (gate == "" || findingsFile == "") {
			return errors.New("ask_user_gate requires --gate and --findings-file")
		}
		if newRequest && (gate != "" || !decisionText(retryKey, 128)) || !newRequest && retryKey != "" {
			return errors.New("--new requires a stable --request-key and no explicit --gate")
		}
		if expires != 0 && (kind == "ask_user_gate" || expires < 60 || expires > 2592000) {
			return errors.New("--expires-in is bounded and available only for non-gate kinds")
		}
		findings := []byte{}
		if findingsFile != "" {
			info, err := os.Stat(findingsFile)
			if err != nil || !info.Mode().IsRegular() || info.Size() > 65536 {
				return errors.New("Findings file must be regular and no larger than 65536 bytes")
			}
			findings, err = os.ReadFile(findingsFile)
			if err != nil {
				return err
			}
			if len(findings) > 65536 || !utf8.Valid(findings) || strings.ContainsRune(string(findings), 0) {
				return errors.New("Findings must be bounded UTF-8 without NUL")
			}
		}
		if len(options) > 20 {
			return errors.New("At most 20 options")
		}
		for _, v := range options {
			if !decisionText(v, 1024) {
				return errors.New("Options must be bounded UTF-8")
			}
		}
		if options == nil {
			options = []string{}
		}
		data := map[string]any{"task": task, "kind": kind, "question": question, "findings": string(findings), "options": options}
		if gate != "" {
			data["gate"] = gate
		}
		if newRequest {
			data["new"] = true
			data["request_key"] = retryKey
		}
		if expires != 0 {
			data["expires_in"] = expires
		}
		return c.request(cmd, http.MethodPost, "decisions", nil, data)
	}
	var promoteTask, sourceType, sourceID, promoteQuestion, promoteKind string
	var revision int
	var promoteOptions []string
	promote := &cobra.Command{Use: "promote TASK", Short: "Explicitly promote a fresh unfiled owner question", Args: cobra.ExactArgs(1)}
	promote.Flags().Bool("captain", true, "Use protected captain/coordinator capability; owners may pass --captain=false")
	promote.Flags().StringVar(&sourceType, "source-type", "", "task_event or message")
	promote.Flags().StringVar(&sourceID, "source-id", "", "Retained source ID")
	promote.Flags().IntVar(&revision, "revision", 0, "Current task revision")
	promote.Flags().StringVar(&promoteQuestion, "question", "", "Explicit captain question")
	promote.Flags().StringVar(&promoteKind, "kind", "approval", "Decision kind")
	promote.Flags().StringArrayVar(&promoteOptions, "option", nil, "Captain choice")
	promote.RunE = func(cmd *cobra.Command, args []string) error {
		promoteTask = args[0]
		if !config.ValidID(promoteTask) || (sourceType != "task_event" && sourceType != "message") || !decisionText(sourceID, 128) || revision < 1 || !decisionText(promoteQuestion, 8192) {
			return errors.New("TASK, source identity, current --revision and --question required")
		}
		if promoteOptions == nil {
			promoteOptions = []string{}
		}
		return c.request(cmd, http.MethodPost, "decisions/promote", nil, map[string]any{"task": promoteTask, "source_type": sourceType, "source_id": sourceID, "revision": revision, "question": promoteQuestion, "kind": promoteKind, "options": promoteOptions})
	}
	group.AddCommand(promote)
	show := &cobra.Command{Use: "show ID", Short: "Read a retained decision verbatim", Args: decisionIDArgs, RunE: func(cmd *cobra.Command, args []string) error {
		return c.request(cmd, http.MethodGet, "decisions/"+args[0], nil, nil)
	}}
	group.AddCommand(request, c.decisionList("decisions"), show, c.decisionWaiting())
	for _, action := range []string{"recommend", "answer", "ack", "withdraw", "supersede"} {
		action := action
		var body, answer, reason, behalf string
		command := &cobra.Command{Use: action + " ID", Short: "Explicit " + action + " of a durable decision", Args: decisionIDArgs}
		switch action {
		case "recommend":
			command.Flags().StringVar(&body, "body", "", "Coordinator recommendation (required)")
		case "answer":
			command.Flags().StringVar(&answer, "answer", "", "Captain-authorized answer (required)")
			command.Flags().StringVar(&behalf, "on-behalf-of", "captain", "Answer authority (captain)")
		case "withdraw", "supersede":
			command.Flags().StringVar(&reason, "reason", "", "Audited reason (required)")
		}
		if action == "recommend" || action == "answer" || action == "supersede" {
			command.Flags().Bool("captain", true, "Use protected AGENTBOARD_CAPTAIN_TOKEN_FILE capability")
		}
		command.RunE = func(cmd *cobra.Command, args []string) error {
			data := map[string]any{}
			switch action {
			case "recommend":
				if strings.TrimSpace(body) == "" {
					return errors.New("--body required")
				}
				data["body"] = body
			case "answer":
				if strings.TrimSpace(answer) == "" || behalf != "captain" {
					return errors.New("--answer and --on-behalf-of captain required")
				}
				data["answer"] = answer
				data["on_behalf_of"] = behalf
			case "withdraw", "supersede":
				if strings.TrimSpace(reason) == "" {
					return errors.New("--reason required")
				}
				data["reason"] = reason
			}
			return c.request(cmd, http.MethodPost, "decisions/"+args[0]+"/"+action, nil, data)
		}
		group.AddCommand(command)
	}
	wake := &cobra.Command{Use: "wake", Short: "Durable seat-watcher reservation and submission disposition"}
	wake.AddCommand(c.decisionList("decisions/wakes"))
	for _, action := range []string{"reserve", "accept", "uncertain"} {
		action := action
		var key, reason string
		command := &cobra.Command{Use: action + " ID", Short: "Record " + action + " without replaying an uncertain native effect", Args: decisionIDArgs}
		command.Flags().Bool("captain", true, "Use protected coordinator/captain capability")
		command.Flags().StringVar(&key, "key", "", "Stable consumer reservation key (required)")
		command.Flags().StringVar(&reason, "reason", "", "Submission uncertainty evidence")
		command.RunE = func(cmd *cobra.Command, args []string) error {
			if strings.TrimSpace(key) == "" {
				return errors.New("--key required")
			}
			data := map[string]any{"key": key}
			if reason != "" {
				data["reason"] = reason
			}
			return c.request(cmd, http.MethodPost, "decisions/wakes/"+args[0]+"/"+action, nil, data)
		}
		wake.AddCommand(command)
	}
	group.AddCommand(wake)
	return group
}

func (c *commands) decisionList(resource string) *cobra.Command {
	var owner, task, status, route, cursor string
	limit := 20
	cmd := &cobra.Command{Use: "list", Short: "Stable oldest-first pages with verbatim findings and claim/staleness state", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&owner, "owner", "", "Requesting seat ID")
	cmd.Flags().StringVar(&task, "task", "", "Task ID")
	cmd.Flags().StringVar(&status, "status", "", "Decision or wake status")
	cmd.Flags().StringVar(&cursor, "cursor", "", "Opaque next_cursor from identical filters")
	cmd.Flags().IntVar(&limit, "limit", 20, "Page size (1–100)")
	if resource == "decisions/wakes" {
		cmd.Flags().StringVar(&route, "route", "", "worker or seat_watcher")
	}
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if limit < 1 || limit > 100 {
			return errors.New("--limit must be 1–100")
		}
		q := url.Values{"limit": {strconv.Itoa(limit)}}
		if stale := c.staleAfter(cmd); stale != "" {
			q.Set("stale_after", stale)
		}
		for k, v := range map[string]string{"owner": owner, "task": task, "status": status, "route": route, "cursor": cursor} {
			if v != "" {
				q.Set(k, v)
			}
		}
		return c.request(cmd, http.MethodGet, resource, q, nil)
	}
	return cmd
}

func decisionText(v string, n int) bool {
	return utf8.ValidString(v) && len(v) <= n && strings.TrimSpace(v) != "" && !strings.ContainsRune(v, 0)
}
func (c *commands) decisionWaiting() *cobra.Command {
	var owner, repo, task, cursor string
	var limit int
	cmd := &cobra.Command{Use: "waiting", Short: "Read exact scoped captain count and bounded formal/unfiled rows", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&owner, "owner", "", "Seat owner")
	cmd.Flags().StringVar(&repo, "repo", "", "Repository owner/name")
	cmd.Flags().StringVar(&task, "task", "", "Task ID")
	cmd.Flags().StringVar(&cursor, "cursor", "", "Filter-bound page cursor")
	cmd.Flags().IntVar(&limit, "limit", 20, "Page size 1–100")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if limit < 1 || limit > 100 {
			return errors.New("--limit must be 1–100")
		}
		q := url.Values{"limit": {strconv.Itoa(limit)}}
		for k, v := range map[string]string{"owner": owner, "repo": repo, "task": task, "cursor": cursor} {
			if v != "" {
				q.Set(k, v)
			}
		}
		return c.request(cmd, http.MethodGet, "decisions/waiting", q, nil)
	}
	return cmd
}
