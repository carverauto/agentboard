package cli

import (
	"errors"
	"io"
	"net/http"
	"os"
	"unicode/utf8"

	"github.com/spf13/cobra"
)

func (c *commands) documents() *cobra.Command {
	group := &cobra.Command{Use: "doc", Short: "Task-linked Archify and OpenSpec HTML documentation"}
	list := &cobra.Command{Use: "list TASK", Short: "List immutable documentation and viewer/download links", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.request(cmd, http.MethodGet, "tasks/"+args[0]+"/documents", nil, nil)
		}}
	file, kind, title, pr, revision, proposal := "", "archify", "", "", "", ""
	push := &cobra.Command{Use: "push TASK", Short: "Upload standalone HTML as the live task owner (up to 2 MiB)", Args: idArgs}
	push.Flags().StringVar(&file, "file", "", "Standalone HTML file (required)")
	push.Flags().StringVar(&kind, "kind", "archify", "archify or openspec")
	push.Flags().StringVar(&title, "title", "", "Documentation title (required)")
	push.Flags().StringVar(&pr, "pr", "", "HTTPS GitHub pull request URL")
	push.Flags().StringVar(&revision, "commit", "", "Source commit SHA (40 lowercase hex characters)")
	push.Flags().StringVar(&proposal, "proposal", "", "OpenSpec change name")
	push.RunE = func(cmd *cobra.Command, args []string) error {
		if file == "" || title == "" || (kind != "archify" && kind != "openspec") {
			return errors.New("--file, --title and kind archify/openspec are required")
		}
		input, err := os.Open(file)
		if err != nil {
			return errors.New("Cannot open documentation file")
		}
		defer input.Close()
		raw, err := io.ReadAll(io.LimitReader(input, (2<<20)+1))
		if err != nil {
			return errors.New("Cannot read documentation file")
		}
		if len(raw) == 0 || len(raw) > 2<<20 || !utf8.Valid(raw) {
			return errors.New("Documentation must be UTF-8 HTML between 1 byte and 2 MiB")
		}
		data := map[string]any{"kind": kind, "title": title, "html": string(raw)}
		for key, value := range map[string]string{"pr_url": pr, "source_revision": revision, "proposal_name": proposal} {
			if value != "" {
				data[key] = value
			}
		}
		return c.request(cmd, http.MethodPost, "tasks/"+args[0]+"/documents", nil, data)
	}
	group.AddCommand(list, push)
	return group
}
