package cli

import (
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/spf13/cobra"
)

func (c *commands) contextCommands() *cobra.Command {
	group := &cobra.Command{Use: "context", Short: "Publish, search and acknowledge durable shared findings"}
	publish := &cobra.Command{Use: "publish", Args: cobra.NoArgs, Short: "Append an attributed finding with a stable retry key"}
	key, repo, kind, summary, file, task, pr, revision := "", "", "OBSERVED", "", "", "", "", ""
	var evidence, links []string
	f := publish.Flags()
	f.StringVar(&key, "key", "", "Stable publication key for this agent (required)")
	f.StringVar(&repo, "repo", "", "Repository owner/name (required)")
	f.StringVar(&kind, "kind", "OBSERVED", "OBSERVED, FACT, FAIL, CLAIM or PATCH_SUMMARY")
	f.StringVar(&summary, "summary", "", "Nonblank summary, up to 600 UTF-8 bytes (required)")
	f.StringVar(&file, "detail-file", "", "UTF-8 detail file, up to 16 KiB")
	f.StringVar(&task, "task", "", "Related task slug")
	f.StringVar(&pr, "pr", "", "Related HTTPS GitHub PR URL")
	f.StringVar(&revision, "commit", "", "Source revision, 40 lowercase hex characters")
	f.StringSliceVar(&evidence, "evidence", nil, "HTTPS evidence URL (repeatable)")
	f.StringArrayVar(&links, "link", nil, "Typed link as relation:ENTRY_ID (repeatable)")
	publish.RunE = func(cmd *cobra.Command, _ []string) error {
		if key == "" || repo == "" || strings.TrimSpace(summary) == "" || len(summary) > 600 || !utf8.ValidString(summary) {
			return errors.New("--key, --repo and --summary (up to 600 UTF-8 bytes) are required")
		}
		detail := ""
		if file != "" {
			input, err := os.Open(file)
			if err != nil {
				return errors.New("Cannot open context detail file")
			}
			defer input.Close()
			raw, err := io.ReadAll(io.LimitReader(input, 16385))
			if err != nil || len(raw) > 16384 || !utf8.Valid(raw) {
				return errors.New("Context detail must be UTF-8 text up to 16 KiB")
			}
			detail = string(raw)
		}
		typed := make([]map[string]any, 0, len(links))
		for _, link := range links {
			parts := strings.SplitN(link, ":", 2)
			if len(parts) != 2 {
				return errors.New("--link requires relation:ENTRY_ID")
			}
			id, err := strconv.ParseInt(parts[1], 10, 64)
			if err != nil || id <= 0 {
				return errors.New("--link requires a positive entry ID")
			}
			typed = append(typed, map[string]any{"target_id": id, "relation": parts[0]})
		}
		if evidence == nil {
			evidence = []string{}
		}
		data := map[string]any{"entry_key": key, "repo": repo, "kind": kind, "summary": summary, "detail": detail, "evidence_urls": evidence, "links": typed}
		for field, value := range map[string]string{"task_id": task, "pr_url": pr, "source_revision": revision} {
			if value != "" {
				data[field] = value
			}
		}
		return c.request(cmd, http.MethodPost, "context", nil, data)
	}
	group.AddCommand(publish)
	for _, op := range []string{"search", "feed"} {
		op := op
		repo, task, kind := "", "", ""
		limit := 50
		args := cobra.NoArgs
		use := op
		if op == "search" {
			args = cobra.ExactArgs(1)
			use += " QUERY"
		}
		cmd := &cobra.Command{Use: use, Args: args, RunE: func(cmd *cobra.Command, args []string) error {
			if repo == "" || limit < 1 || limit > 100 {
				return errors.New("--repo and --limit 1–100 are required")
			}
			query := url.Values{"repo": {repo}, "limit": {strconv.Itoa(limit)}}
			if task != "" {
				query.Set("task", task)
			}
			if kind != "" {
				query.Set("kind", kind)
			}
			if op == "search" {
				query.Set("q", args[0])
			}
			return c.request(cmd, http.MethodGet, "context/"+op, query, nil)
		}}
		cmd.Flags().StringVar(&repo, "repo", "", "Repository owner/name (required)")
		cmd.Flags().StringVar(&task, "task", "", "Related task filter")
		cmd.Flags().StringVar(&kind, "kind", "", "Entry kind filter")
		cmd.Flags().IntVar(&limit, "limit", 50, "Maximum entries (1–100)")
		group.AddCommand(cmd)
	}
	for _, op := range []string{"show", "ack"} {
		op := op
		group.AddCommand(&cobra.Command{Use: op + " ENTRY_ID", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
			id, err := strconv.ParseInt(args[0], 10, 64)
			if err != nil || id <= 0 {
				return errors.New("Entry ID must be positive")
			}
			method, path := http.MethodGet, "context/"+args[0]
			if op == "ack" {
				method = http.MethodPost
				path += "/ack"
			}
			return c.request(cmd, method, path, nil, nil)
		}})
	}
	return group
}
