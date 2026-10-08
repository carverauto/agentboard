package cli

import (
	"errors"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"

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
	var task, kind, gate, question, findingsFile string
	var options []string
	request := &cobra.Command{Use: "request", Short: "Block your owned task with one verbatim task/gate request", Args: cobra.NoArgs}
	request.Flags().StringVar(&task, "task", "", "Owned task (required)")
	request.Flags().StringVar(&kind, "kind", "ask_user_gate", "ask_user_gate, approval, blocked_decision or other")
	request.Flags().StringVar(&gate, "gate", "", "Stable run/gate reference (required)")
	request.Flags().StringVar(&question, "question", "", "Verbatim bounded question (required)")
	request.Flags().StringVar(&findingsFile, "findings-file", "", "UTF-8 verbatim findings file (required; may be empty)")
	request.Flags().StringArrayVar(&options, "option", nil, "Optional choice; repeat for each option")
	request.RunE = func(cmd *cobra.Command, args []string) error {
		if !config.ValidID(task) || strings.TrimSpace(gate) == "" || strings.TrimSpace(question) == "" || findingsFile == "" {
			return errors.New("--task, --gate, --question and --findings-file are required")
		}
		info, err := os.Stat(findingsFile)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 65536 {
			return errors.New("Findings file must be a regular file no larger than 65536 bytes")
		}
		findings, err := os.ReadFile(findingsFile)
		if err != nil {
			return err
		}
		if options == nil {
			options = []string{}
		}
		return c.request(cmd, http.MethodPost, "decisions", nil, map[string]any{"task": task, "kind": kind, "gate": gate, "question": question, "findings": string(findings), "options": options})
	}
	show := &cobra.Command{Use: "show ID", Short: "Read a retained decision verbatim", Args: decisionIDArgs, RunE: func(cmd *cobra.Command, args []string) error {
		return c.request(cmd, http.MethodGet, "decisions/"+args[0], nil, nil)
	}}
	group.AddCommand(request, c.decisionList("decisions"), show)
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
