package cli

import (
	"errors"
	"net/http"
	"net/url"
	"strconv"

	"github.com/carverauto/agentboard/internal/config"
	"github.com/spf13/cobra"
)

func idArgs(cmd *cobra.Command, args []string) error {
	if err := cobra.ExactArgs(1)(cmd, args); err != nil {
		return err
	}
	if !config.ValidID(args[0]) {
		return errors.New("ID must be a lowercase agent/task slug")
	}
	return nil
}
func (c *commands) list(resource string, filters []string) *cobra.Command {
	cmd := &cobra.Command{Use: "list", Short: "List records with bounded keyset pagination", Args: cobra.NoArgs}
	limit := 100
	cursor := ""
	values := map[string]*string{}
	cmd.Flags().IntVar(&limit, "limit", 100, "Page size (1–1000)")
	cmd.Flags().StringVar(&cursor, "cursor", "", "Opaque next_cursor from the same filters")
	for _, key := range filters {
		v := new(string)
		values[key] = v
		cmd.Flags().StringVar(v, key, "", "Filter by "+key)
	}
	watch := false
	if resource != "agents" {
		cmd.Flags().BoolVar(&watch, "watch", false, "Watch complete snapshots instead of a single page")
	}
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if limit < 1 || limit > 1000 {
			return errors.New("--limit must be 1–1000")
		}
		q := url.Values{"limit": {strconv.Itoa(limit)}}
		if cursor != "" {
			q.Set("cursor", cursor)
		}
		if resource == "agents" || resource == "quota" {
			if stale := c.staleAfter(cmd); stale != "" {
				q.Set("stale_after", stale)
			}
		}
		for k, v := range values {
			if *v != "" {
				q.Set(k, *v)
			}
		}
		messageQuery(cmd, q)
		if watch {
			return c.watch(cmd, resource, q)
		}
		return c.request(cmd, http.MethodGet, resource, q, nil)
	}
	return cmd
}
func (c *commands) show(resource string) *cobra.Command {
	limit := 100
	cursor := ""
	cmd := &cobra.Command{Use: "show ID", Short: "Show a record and its attributed history", Args: idArgs}
	cmd.Flags().IntVar(&limit, "limit", 100, "Timeline page size (1–1000)")
	cmd.Flags().StringVar(&cursor, "cursor", "", "Timeline next_cursor")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		q := url.Values{}
		if resource == "tasks" {
			q.Set("limit", strconv.Itoa(limit))
			if cursor != "" {
				q.Set("cursor", cursor)
			}
		}
		if resource == "agents" {
			if stale := c.staleAfter(cmd); stale != "" {
				q.Set("stale_after", stale)
			}
		}
		return c.request(cmd, http.MethodGet, resource+"/"+args[0], q, nil)
	}
	return cmd
}
func (c *commands) agents() *cobra.Command {
	group := &cobra.Command{Use: "agent", Short: "Stable registry and heartbeat identity"}
	group.AddCommand(c.list("agents", []string{"harness", "status", "availability", "waiting", "kind", "retired"}), c.show("agents"))
	name, host, backend, kind := "", "", "", ""
	caps := []string{}
	register := &cobra.Command{Use: "register", Short: "Create or refresh this agent; a different harness cannot reuse its ID", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			data := map[string]any{}
			if name != "" {
				data["name"] = name
			}
			if kind != "" {
				switch kind {
				case "seat", "human", "system", "fixture":
					data["kind"] = kind
				default:
					return errors.New("--kind must be seat, human, system, or fixture")
				}
			}
			if host != "" {
				data["host"] = host
			}
			if cmd.Flags().Changed("capability") {
				data["capabilities"] = caps
			}
			if backend != "" {
				data["metadata"] = map[string]string{"backend": backend}
			}
			return c.request(cmd, http.MethodPost, "agents/register", nil, data)
		}}
	register.Flags().StringVar(&name, "name", "", "Descriptive agent name")
	register.Flags().StringVar(&kind, "kind", "", "Identity kind: seat, human, system, or fixture")
	register.Flags().StringVar(&host, "host", "", "Host/session label")
	register.Flags().StringSliceVar(&caps, "capability", nil, "Comma-separated capabilities")
	register.Flags().StringVar(&backend, "backend", "", "Optional backend metadata (e.g. herdr)")
	reason, force := "", false
	retire := &cobra.Command{Use: "retire ID", Short: "Captain-gated tombstone retire of an identity (idempotent)", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if reason == "" {
				return errors.New("--reason is required")
			}
			data := map[string]any{"reason": reason}
			if force {
				data["force"] = true
			}
			return c.request(cmd, http.MethodPost, "agents/"+args[0]+"/retire", nil, data)
		}}
	retire.Flags().StringVar(&reason, "reason", "", "Why this identity retires")
	retire.Flags().BoolVar(&force, "force", false, "Retire despite a live claim or open decision (reason still required)")
	retire.Flags().Bool("captain", true, "Use protected AGENTBOARD_CAPTAIN_TOKEN_FILE capability")
	restore := &cobra.Command{Use: "restore ID", Short: "Captain-gated restore of a retired identity (idempotent)", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.request(cmd, http.MethodPost, "agents/"+args[0]+"/restore", nil, map[string]any{})
		}}
	restore.Flags().Bool("captain", true, "Use protected AGENTBOARD_CAPTAIN_TOKEN_FILE capability")
	group.AddCommand(register, retire, restore, c.heartbeat(), c.availabilityCommands(), c.agentTokens())
	return group
}
func (c *commands) tasks() *cobra.Command {
	group := &cobra.Command{Use: "task", Short: "Task records, ownership leases, and append-only timeline"}
	group.AddCommand(c.list("tasks", []string{"status", "owner", "repo", "label"}), c.show("tasks"), c.watchCommand("tasks", []string{"status", "owner", "repo", "label"}))
	for _, action := range []string{"create", "edit", "link"} {
		group.AddCommand(c.taskMetadata(action))
	}
	for _, action := range []string{"assign", "claim", "renew", "release", "reclaim", "update", "handoff"} {
		group.AddCommand(c.taskAction(action))
	}
	return group
}

func (c *commands) taskMetadata(action string) *cobra.Command {
	data := map[string]any{}
	title, description, repo, issue, pr, id := "", "", "", "", "", ""
	priority := 3
	labels := []string{}
	revision := int64(0)
	use := action + " ID"
	args := idArgs
	if action == "create" {
		use = "create"
		args = cobra.NoArgs
	}
	cmd := &cobra.Command{Use: use, Short: action + " task metadata", Args: args}
	if action != "link" {
		cmd.Flags().StringVar(&title, "title", "", "Task title")
		cmd.Flags().StringVar(&description, "description", "", "Task description")
		cmd.Flags().IntVar(&priority, "priority", 3, "Priority (nonnegative; lower is sooner)")
		cmd.Flags().StringVar(&repo, "repo", "", "Repository label")
		cmd.Flags().StringSliceVar(&labels, "label", nil, "Comma-separated labels")
	}
	cmd.Flags().StringVar(&issue, "issue", "", "HTTPS GitHub issue URL; empty clears the link")
	cmd.Flags().StringVar(&pr, "pr", "", "HTTPS GitHub PR URL; empty clears the link")
	if action == "create" {
		cmd.Flags().StringVar(&id, "id", "", "Stable task slug; defaults to title plus random suffix")
	} else {
		cmd.Flags().Int64Var(&revision, "revision", 0, "Expected task revision (optional)")
	}
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if action == "create" && title == "" {
			return errors.New("--title is required")
		}
		if priority < 0 {
			return errors.New("--priority must be nonnegative")
		}
		for key, value := range map[string]any{"title": title, "description": description, "priority": priority, "repo": repo, "labels": labels, "issue_url": issue, "pr_url": pr} {
			flag := key
			switch key {
			case "labels":
				flag = "label"
			case "issue_url":
				flag = "issue"
			case "pr_url":
				flag = "pr"
			}
			if cmd.Flags().Changed(flag) || (action == "create" && (key == "title" || key == "priority")) {
				if (key == "issue_url" || key == "pr_url") && value == "" {
					value = nil
				}
				data[key] = value
			}
		}
		if action == "create" {
			if id != "" {
				data["id"] = id
			}
			return c.request(cmd, http.MethodPost, "tasks", nil, data)
		}
		if revision != 0 {
			data["revision"] = revision
		}
		path := "tasks/" + args[0]
		method := http.MethodPatch
		if action == "link" {
			method = http.MethodPost
			path += "/link"
		}
		return c.request(cmd, method, path, nil, data)
	}
	return cmd
}

func (c *commands) taskAction(action string) *cobra.Command {
	to, note, status, kind := "", "", "", "note"
	expired := false
	revision := int64(0)
	cmd := &cobra.Command{Use: action + " ID", Short: action + " task ownership or progress", Args: idArgs}
	if action == "assign" || action == "handoff" {
		cmd.Flags().Bool("captain", false, "Authorize named assignment using AGENTBOARD_CAPTAIN_TOKEN_FILE")
		cmd.Flags().StringVar(&to, "to", "", "Registered assignee ID")
	}
	if action == "release" {
		cmd.Flags().BoolVar(&expired, "expired", false, "Explicitly release someone else's expired claim")
	}
	if action == "handoff" {
		cmd.Flags().StringVar(&note, "body", "", "Handoff reason (required)")
	}
	if action == "update" {
		cmd.Flags().StringVar(&note, "body", "", "Progress note / reason (required for blocked)")
		cmd.Flags().StringVar(&status, "status", "", "Status transition")
		cmd.Flags().StringVar(&kind, "kind", "note", "note or status (compatibility flag)")
	}
	cmd.Flags().Int64Var(&revision, "revision", 0, "Expected task revision (optional)")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		data := map[string]any{}
		if revision != 0 {
			data["revision"] = revision
		}
		switch action {
		case "assign":
			if !config.ValidID(to) {
				return errors.New("--to must name a registered agent slug")
			}
			data["to"] = to
		case "handoff":
			if !config.ValidID(to) || note == "" {
				return errors.New("--to and --body are required")
			}
			data["to"] = to
			data["note"] = note
		case "claim", "renew", "reclaim":
			data["ttl_seconds"] = c.cfg.ClaimTTL.Seconds()
		case "release":
			data["expired"] = expired
		case "update":
			if kind != "note" && kind != "status" {
				return errors.New("--kind must be note or status")
			}
			if note != "" {
				data["note"] = note
			}
			if status != "" {
				data["status"] = status
			}
		}
		return c.request(cmd, http.MethodPost, "tasks/"+args[0]+"/"+action, nil, data)
	}
	return cmd
}
