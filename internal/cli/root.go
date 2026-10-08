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
	"strings"
	"text/tabwriter"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
	"github.com/spf13/cobra"
)

const Version = "0.1.0"

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
	f.StringVar(&c.stale, "stale-after", c.stale, "Liveness threshold (AGENTBOARD_STALE_AFTER; default 10m)")
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
		_, err = fmt.Fprintln(cmd.OutOrStdout(), string(result))
		return err
	}})
	root.AddCommand(&cobra.Command{Use: "version", Short: "Print CLI version", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		_, err := fmt.Fprintln(cmd.OutOrStdout(), Version)
		return err
	}})
	root.AddCommand(c.agents(), c.tasks(), c.messages(), c.quota(), c.documents(), c.skills(), c.contextCommands(), c.workerCommands(), c.chat(), c.prs())
	return root
}
func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func (c *commands) request(cmd *cobra.Command, method, path string, query url.Values, payload any) error {
	if method != http.MethodGet {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
	}
	api, err := client.New(c.cfg)
	if err != nil {
		return err
	}
	defer api.Close()
	raw, err := api.JSON(cmd.Context(), http.MethodGet, "meta", nil, nil)
	if err != nil {
		return err
	}
	var meta struct {
		API    int `json:"api_version"`
		Schema int `json:"schema_version"`
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
	if strings.HasPrefix(path, "conversations") {
		required = 12
	}
	if strings.HasSuffix(path, "/documents") {
		required = 4
	}
	if json.Unmarshal(raw, &meta) != nil || meta.API != 1 || meta.Schema < required {
		return &client.Error{Code: "schema_unavailable", Message: "API or schema is incompatible; an operator must run release migrations"}
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
	for _, key := range []string{"agent", "agents", "task", "tasks", "events", "messages", "message", "quota", "report", "document", "documents", "entry", "entries", "chat", "post", "posts"} {
		value, ok := envelope[key]
		if !ok {
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
	if next := envelope["next_cursor"]; next != nil {
		fmt.Fprintf(table, "next_cursor\t%v\n", next)
	}
	if acknowledged := envelope["acknowledged"]; acknowledged != nil {
		fmt.Fprintf(table, "acknowledged\t%v\n", acknowledged)
	}
	if dupe, ok := envelope["duplicate"]; ok {
		fmt.Fprintf(table, "duplicate\t%v\n", dupe)
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
		fmt.Fprintf(table, "%v\t%v\t%v\tstale=%v\n", r["id"], r["harness"], r["model"], r["stale"])
	} else {
		encoded, _ := json.Marshal(r)
		fmt.Fprintln(table, string(encoded))
	}
}
