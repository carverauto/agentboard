// Package cli exposes the agentboard command interface.
package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

const Version = "0.1.0"
const DecisionIntakeVersion = 1

type commands struct {
	cfg        config.Config
	json       bool
	ttl, stale string
}

func NewRoot() *cobra.Command {
	cfg, _ := config.FromEnv()
	c := &commands{cfg: cfg, ttl: env("AGENTBOARD_CLAIM_TTL", "2h"), stale: env("AGENTBOARD_STALE_AFTER", "10m")}
	root := &cobra.Command{Use: "agentboard", Short: "Shared task board for coding agents", SilenceErrors: true, SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error { return cmd.Help() },
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			if cmd.Name() == "version" {
				return nil
			}
			var err error
			c.cfg.ClaimTTL, err = config.PositiveDuration(c.ttl)
			if err != nil {
				return errors.New("--ttl / AGENTBOARD_CLAIM_TTL must be a positive duration")
			}
			c.cfg.StaleAfter, err = config.PositiveDuration(c.stale)
			if err != nil {
				return errors.New("--stale-after / AGENTBOARD_STALE_AFTER must be a positive duration")
			}
			return nil
		},
	}
	f := root.PersistentFlags()
	f.StringVar(&c.cfg.Actor.ID, "agent", cfg.Actor.ID, "Stable agent ID (AGENT_ID)")
	f.StringVar(&c.cfg.Actor.Model, "model", cfg.Actor.Model, "Model stamped on writes (AGENTBOARD_MODEL)")
	f.StringVar(&c.cfg.Actor.Harness, "harness", cfg.Actor.Harness, "Harness stamped on writes (AGENTBOARD_HARNESS)")
	f.StringVar(&c.cfg.URL, "url", cfg.URL, "Phoenix API base URL (AGENTBOARD_URL)")
	f.StringVar(&c.cfg.CAFile, "ca-file", cfg.CAFile, "Additional trusted HTTPS CA PEM (AGENTBOARD_CA_FILE)")
	f.BoolVar(&c.json, "json", false, "Emit JSON records; JSON errors use stderr")
	f.StringVar(&c.ttl, "ttl", c.ttl, "Claim/renew/reclaim lease (AGENTBOARD_CLAIM_TTL; default 2h)")
	f.StringVar(&c.stale, "stale-after", c.stale, "Liveness threshold (AGENTBOARD_STALE_AFTER; unset means server default)")
	root.AddCommand(&cobra.Command{Use: "meta", Short: "Show API and schema compatibility metadata", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		api, err := client.New(c.cfg)
		if err != nil {
			return err
		}
		defer api.Close()
		result, err := api.JSON(cmd.Context(), http.MethodGet, "meta", nil, nil)
		if err != nil {
			return err
		}
		var metadata map[string]any
		if err = json.Unmarshal(result, &metadata); err != nil {
			return err
		}
		metadata["cli_version"] = Version
		metadata["cli_capabilities"] = map[string]any{"decision_intake": DecisionIntakeVersion}
		err = json.NewEncoder(cmd.OutOrStdout()).Encode(metadata)
		return err
	}})
	root.AddCommand(&cobra.Command{Use: "version", Short: "Print CLI version", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		_, err := fmt.Fprintln(cmd.OutOrStdout(), Version)
		return err
	}})
	root.AddCommand(c.doctor())
	root.AddCommand(c.agents(), c.tasks(), c.messages(), c.quota(), c.documents(), c.skills(), c.contextCommands(), c.workerCommands(), c.hostCommands(), c.chat(), c.prs(), c.decisions(), c.seat(), c.adminCommands(), c.fleetCommands())
	return root
}
func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func (c *commands) staleAfter(cmd *cobra.Command) string {
	if os.Getenv("AGENTBOARD_STALE_AFTER") != "" {
		return strconv.FormatFloat(c.cfg.StaleAfter.Seconds(), 'f', -1, 64)
	}
	if cmd.Root().PersistentFlags().Changed("stale-after") {
		return strconv.FormatFloat(c.cfg.StaleAfter.Seconds(), 'f', -1, 64)
	}
	return ""
}

func (c *commands) request(cmd *cobra.Command, method, path string, query url.Values, payload any) error {
	// Fleet authority and audit attribution come from verified captain transport,
	// not the caller's self-reported actor environment.
	fleetLoadout := strings.HasPrefix(path, "fleets/") && strings.HasSuffix(path, "/loadout")
	if method != http.MethodGet && !fleetLoadout {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
	}
	var api *client.Client
	var err error
	captain, _ := cmd.Flags().GetBool("captain")
	// Fleet configuration is captain-only for reads as well as writes. There is
	// no command flag that can downgrade this transport to an ordinary bearer.
	captain = captain || fleetLoadout
	if captain {
		secret, readErr := worker.ReadProtected(os.Getenv("AGENTBOARD_CAPTAIN_TOKEN_FILE"), 4096)
		if readErr != nil {
			return errors.New("AGENTBOARD_CAPTAIN_TOKEN_FILE must be a protected captain capability file")
		}
		api, err = client.NewCaptain(c.cfg, strings.TrimSpace(string(secret)))
	} else {
		api, err = client.New(c.cfg)
	}
	if err != nil {
		return err
	}
	defer api.Close()
	raw, err := api.JSON(cmd.Context(), http.MethodGet, "meta", nil, nil)
	if err != nil {
		return err
	}
	var meta struct {
		API            int `json:"api_version"`
		Schema         int `json:"schema_version"`
		DecisionIntake int `json:"required_decision_intake_version"`
	}
	required := 1
	if strings.HasPrefix(path, "messages") || strings.HasSuffix(path, "/heartbeat") || strings.HasSuffix(path, "/handoff") {
		required = 2
	}
	if strings.HasPrefix(path, "quota") {
		required = 3
	}
	if strings.HasPrefix(path, "context") {
		required = 5
	}
	if strings.HasPrefix(path, "prs") {
		required = 14
	}
	if strings.HasPrefix(path, "availability") || path == "messages/task-orders" {
		required = 15
	}
	if strings.HasPrefix(path, "conversations") {
		required = 12
	}
	if strings.HasSuffix(path, "/documents") {
		required = 4
	}
	if captain || query.Get("availability") != "" {
		required = 15
	}
	if fields, ok := payload.(map[string]any); ok && fields["kind"] == "task_order" {
		required = 15
	}
	if strings.HasPrefix(path, "decisions") || query.Get("waiting") != "" {
		required = 20
	}
	if path == "decisions/waiting" || path == "decisions/promote" {
		required = 29
	}
	if path == "decisions" && method == http.MethodPost {
		if fields, ok := payload.(map[string]any); ok {
			if fields["gate"] == nil || fields["new"] == true || fields["expires_in"] != nil {
				required = 29
			}
			switch fields["kind"] {
			case "merge", "scope", "policy", "credential":
				required = 29
			}
		}
	}
	if strings.HasSuffix(path, "/duplicate-decision") {
		required = 24
	}
	if strings.HasSuffix(path, "/retire") || strings.HasSuffix(path, "/restore") {
		required = 30
	}
	if strings.HasPrefix(path, "agents/") && strings.HasSuffix(path, "/scope") {
		required = 34
	}
	if fleetLoadout {
		required = 35
	}
	if fields, ok := payload.(map[string]any); ok {
		if kind, ok := fields["kind"].(string); ok && (kind == "seat" || kind == "human" || kind == "system" || kind == "fixture") {
			required = 30
		}
	}
	if strings.HasPrefix(path, "agents") && (query.Get("kind") != "" || query.Get("retired") != "") {
		required = 30
	}
	// Exact non-consuming reads, metadata writes and triage filters must not
	// silently degrade on older servers. Legacy message operations stay at 2
	// (or 15 for task orders), and use their existing watch compatibility path.
	if method == http.MethodGet && strings.HasPrefix(path, "messages/") || path == "messages" && query.Get("triage_state") != "" {
		required = 36
	}
	if path == "messages" && method == http.MethodPost {
		if fields, ok := payload.(map[string]any); ok {
			if _, present := fields["triage"]; present {
				required = 36
			}
		}
	}
	if json.Unmarshal(raw, &meta) != nil || meta.API != 1 || meta.Schema < required {
		return &client.Error{Code: "schema_unavailable", Message: "API or schema is incompatible; an operator must run release migrations"}
	}
	if meta.DecisionIntake > DecisionIntakeVersion {
		warning := "Installed CLI lacks required decision intake; upgrade from a SHA256SUMS-verified agentboard release"
		if c.json {
			_ = json.NewEncoder(cmd.ErrOrStderr()).Encode(map[string]any{"warning": map[string]any{"code": "cli_incompatible", "message": warning, "required": meta.DecisionIntake, "supported": DecisionIntakeVersion}})
		} else {
			fmt.Fprintln(cmd.ErrOrStderr(), warning)
		}
	}
	raw, err = api.JSON(cmd.Context(), method, path, query, payload)
	if err != nil {
		return err
	}
	return c.output(cmd.OutOrStdout(), raw)
}
func (c *commands) output(w io.Writer, raw json.RawMessage) error {
	if c.json {
		_, err := fmt.Fprintln(w, string(raw))
		return err
	}
	var envelope map[string]any
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return err
	}
	table := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	for _, key := range []string{"agent", "agents", "scope", "loadout", "task", "tasks", "events", "messages", "message", "triage", "quota", "report", "document", "documents", "policy", "policies", "entry", "entries", "chat", "post", "posts", "decision", "decisions", "wake", "wakes"} {
		value, ok := envelope[key]
		if !ok {
			continue
		}
		if key == "triage" && value == nil {
			fmt.Fprintln(table, "triage\tnull")
			continue
		}
		records, ok := value.([]any)
		if !ok {
			records = []any{value}
		}
		for _, record := range records {
			r, ok := record.(map[string]any)
			if !ok {
				continue
			}
			printRecord(table, r)
		}
	}
	if recipients := envelope["recipient_ids"]; recipients != nil {
		encoded, _ := json.Marshal(envelope)
		fmt.Fprintln(table, string(encoded))
	}
	if next := envelope["next_cursor"]; next != nil {
		fmt.Fprintf(table, "next_cursor\t%v\n", next)
	}
	if acknowledged := envelope["acknowledged"]; acknowledged != nil {
		fmt.Fprintf(table, "acknowledged\t%v\n", acknowledged)
	}
	if dupe, ok := envelope["duplicate"]; ok {
		fmt.Fprintf(table, "duplicate\t%v\n", dupe)
	}
	if replayed, ok := envelope["replayed"]; ok {
		fmt.Fprintf(table, "replayed\t%v\n", replayed)
	}
	if caughtUp, ok := envelope["caught_up"]; ok {
		fmt.Fprintf(table, "caught_up\t%v\n", caughtUp)
	}
	if more, ok := envelope["more"]; ok {
		fmt.Fprintf(table, "more\t%v\n", more)
	}
	return table.Flush()
}
func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	var coded interface{ ExitCode() int }
	if errors.As(err, &coded) {
		return coded.ExitCode()
	}
	return 2
}
func PrintError(root *cobra.Command, w io.Writer, err error) {
	asJSON, _ := root.PersistentFlags().GetBool("json")
	if asJSON {
		code := "invalid_input"
		var e *client.Error
		if errors.As(err, &e) {
			code = e.Code
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": code, "message": err.Error()}})
	} else {
		fmt.Fprintln(w, "agentboard:", err)
	}
}

func printRecord(table io.Writer, r map[string]any) {
	if r["viewer_url"] != nil {
		fmt.Fprintf(table, "%v\t%v\t%v\t%v\t%v\n", r["id"], r["kind"], r["source_agent_id"], r["title"], r["viewer_url"])
	} else if r["title"] != nil {
		fmt.Fprintf(table, "%v\t%v\t%v\texpired=%v\t%v\n", r["id"], r["status"], r["assignee_id"], r["claim_expired"], r["title"])
	} else if r["name"] != nil {
		availability := "active"
		if policy, ok := r["availability"].(map[string]any); ok {
			availability, _ = policy["state"].(string)
		}
		fmt.Fprintf(table, "%v\t%v\t%v\tstale=%v\tavailability=%s\n", r["id"], r["harness"], r["model"], r["stale"], availability)
	} else {
		encoded, _ := json.Marshal(r)
		fmt.Fprintln(table, string(encoded))
	}
}

func (c *commands) doctor() *cobra.Command {
	return &cobra.Command{Use: "doctor", Short: "Read-only API and decision-intake compatibility check", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		api, err := client.New(c.cfg)
		if err != nil {
			return err
		}
		defer api.Close()
		raw, err := api.JSON(cmd.Context(), http.MethodGet, "meta", nil, nil)
		if err != nil {
			return err
		}
		var m struct {
			API      int `json:"api_version"`
			Schema   int `json:"schema_version"`
			Required int `json:"required_decision_intake_version"`
		}
		if err = json.Unmarshal(raw, &m); err != nil {
			return err
		}
		compatible := m.API == 1 && m.Schema >= 29 && m.Required >= 1 && m.Required <= DecisionIntakeVersion
		diagnostic := map[string]any{"compatible": compatible, "cli_version": Version, "cli_capabilities": map[string]any{"decision_intake": DecisionIntakeVersion}, "required_decision_intake_version": m.Required, "schema_version": m.Schema}
		if !compatible {
			diagnostic["upgrade_hint"] = "Install a current agentboard release after verifying SHA256SUMS; operator must provide decision-intake compatible server"
		}
		if err = json.NewEncoder(cmd.OutOrStdout()).Encode(diagnostic); err != nil {
			return err
		}
		if !compatible {
			return &client.Error{Code: "schema_unavailable", Message: "CLI/server decision intake is incompatible; verify release SHA256SUMS before upgrading"}
		}
		return nil
	}}
}
