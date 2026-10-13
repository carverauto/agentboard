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
	"unicode/utf8"

	"github.com/spf13/cobra"
)

// Work intake files board cards and, optionally, GitHub issues through the
// server's idempotent intake contract. Intake requires the protected captain
// capability (AGENTBOARD_CAPTAIN_TOKEN_FILE) for now. It only files work: it
// never claims, assigns or coordinates. Re-running `intake file` with the same
// --request-key and payload replays the original request instead of filing
// twice; a changed payload under that key is a conflict (exit 4). `intake
// import` turns existing open issues into cards linked to them and creates
// no issue.

const intakeFileLimit = 1 << 20

// intakeUncertain reports an issue intent that needs an explicit
// reconcile or abandon decision.
type intakeUncertain struct{ request string }

func (e *intakeUncertain) Error() string {
	return fmt.Sprintf("intake %s has an uncertain issue; inspect it and run `agentboard intake resolve %s ITEM --action reconcile|abandon`", e.request, e.request)
}
func (e *intakeUncertain) ExitCode() int     { return 5 }
func (e *intakeUncertain) ErrorCode() string { return "intake_uncertain" }

type intakeView struct {
	Intake struct {
		ID         string `json:"id"`
		RequestKey string `json:"request_key"`
		Items      []struct {
			ID         string  `json:"id"`
			Position   int     `json:"position"`
			TaskID     string  `json:"task_id"`
			TaskStatus *string `json:"task_status"`
			Repository string  `json:"repository"`
			IssueState string  `json:"issue_state"`
			IssueURL   *string `json:"issue_url"`
			Reason     *string `json:"reason"`
			LastError  *string `json:"last_error"`
		} `json:"items"`
		Import *struct {
			Bounded  bool `json:"bounded"`
			NextPage *int `json:"next_page"`
			Skipped  []struct {
				IssueNumber int     `json:"issue_number"`
				Reason      string  `json:"reason"`
				TaskID      *string `json:"task_id"`
			} `json:"skipped"`
		} `json:"import"`
	} `json:"intake"`
	Replayed  bool             `json:"replayed"`
	Cancelled []string         `json:"cancelled"`
	Skipped   []map[string]any `json:"skipped"`
}

func (c *commands) intakeCommands() *cobra.Command {
	group := &cobra.Command{Use: "intake", Short: "File cards and GitHub issues, or card existing issues, through the idempotent intake API (captain capability)"}
	group.AddCommand(c.intakeFile(), c.intakeImport(), c.intakeStatus(), c.intakeCancel(), c.intakeResolve())
	return group
}

func (c *commands) intakeFile() *cobra.Command {
	var key, repo, title, body, bodyFile, file string
	var priority int
	var labels []string
	var noIssue bool
	cmd := &cobra.Command{Use: "file --request-key KEY (--repo OWNER/REPO --title TITLE | --file PATH)", Short: "File one item from flags or up to 10 items from a JSON file", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			var payload map[string]any
			if file != "" {
				if repo != "" || title != "" || body != "" || bodyFile != "" || len(labels) > 0 || noIssue || cmd.Flags().Changed("priority") {
					return errors.New("--file cannot be combined with item flags")
				}
				items, err := readIntakeItems(file)
				if err != nil {
					return err
				}
				payload = map[string]any{"items": items}
			} else {
				if repo == "" || strings.TrimSpace(title) == "" {
					return errors.New("--repo and --title are required unless --file is given")
				}
				if body != "" && bodyFile != "" {
					return errors.New("use --body or --body-file, not both")
				}
				if bodyFile != "" {
					raw, err := readBounded(bodyFile, intakeFileLimit)
					if err != nil {
						return err
					}
					body = string(raw)
				}
				item := map[string]any{"repository": repo, "title": title, "issue": !noIssue}
				if body != "" {
					item["body"] = body
				}
				if cmd.Flags().Changed("priority") {
					item["priority"] = priority
				}
				if len(labels) > 0 {
					item["labels"] = labels
				}
				payload = map[string]any{"items": []any{item}}
			}
			if strings.TrimSpace(key) == "" {
				return errors.New("--request-key is required; reuse it to retry safely")
			}
			payload["request_key"] = key
			raw, err := c.call(cmd, http.MethodPost, "intake", nil, payload)
			if err != nil {
				return err
			}
			return c.printIntake(cmd, raw, false)
		}}
	f := cmd.Flags()
	f.StringVar(&key, "request-key", "", "Idempotency key (1-128 bytes); a retry with the same key and payload replays")
	f.StringVar(&repo, "repo", "", "Repository owner/repo; must be in the server's intake repository list")
	f.StringVar(&title, "title", "", "Card and issue title")
	f.StringVar(&body, "body", "", "Card and issue body")
	f.StringVar(&bodyFile, "body-file", "", "Read the body from a UTF-8 file (up to 1 MiB)")
	f.IntVar(&priority, "priority", 3, "Board priority; lower is more urgent")
	f.StringArrayVar(&labels, "label", nil, "Label (repeatable)")
	f.BoolVar(&noIssue, "no-issue", false, "File a card only; do not create a GitHub issue")
	f.StringVar(&file, "file", "", `JSON items file: [{"repository":"o/r","title":"...","body":"...","priority":2,"labels":["x"],"issue":true}]`)
	return cmd
}

func (c *commands) intakeImport() *cobra.Command {
	var key, repo string
	var issues []int
	var labels []string
	var limit, priority, startPage int
	cmd := &cobra.Command{Use: "import --request-key KEY --repo OWNER/REPO ([--issue N]... | [--label L]... [--limit N] [--start-page N])", Short: "Card existing open issues: named numbers in order, or the first N open issues not yet on the board", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if strings.TrimSpace(key) == "" {
				return errors.New("--request-key is required; reuse it to retry safely")
			}
			if repo == "" {
				return errors.New("--repo is required")
			}
			payload := map[string]any{"request_key": key, "repository": repo}
			if len(issues) > 0 {
				if len(labels) > 0 || cmd.Flags().Changed("limit") || cmd.Flags().Changed("start-page") {
					return errors.New("--issue cannot be combined with --label, --limit, or --start-page")
				}
				payload["issues"] = issues
			} else {
				if len(labels) > 0 {
					payload["labels"] = labels
				}
				if cmd.Flags().Changed("limit") {
					payload["limit"] = limit
				}
				if cmd.Flags().Changed("start-page") {
					if startPage < 1 {
						return errors.New("--start-page must be at least 1")
					}
					payload["start_page"] = startPage
				}
			}
			if cmd.Flags().Changed("priority") {
				payload["priority"] = priority
			}
			raw, err := c.call(cmd, http.MethodPost, "intake/import", nil, payload)
			if err != nil {
				return err
			}
			return c.printIntake(cmd, raw, false)
		}}
	f := cmd.Flags()
	f.StringVar(&key, "request-key", "", "Idempotency key (1-128 bytes); a retry with the same key and selection replays without reading GitHub")
	f.StringVar(&repo, "repo", "", "Repository owner/repo; must be in the server's intake repository list")
	f.IntSliceVar(&issues, "issue", nil, "Issue number to import, in order (repeatable, up to 10)")
	f.StringArrayVar(&labels, "label", nil, "Only list open issues carrying this label (repeatable)")
	f.IntVar(&limit, "limit", 10, "How many open issues not yet on the board to import (1-10)")
	f.IntVar(&startPage, "start-page", 1, "Open-issue list page to start from; pass the previous import's next page to continue")
	f.IntVar(&priority, "priority", 3, "Board priority for every imported card; lower is more urgent")
	return cmd
}

func (c *commands) intakeStatus() *cobra.Command {
	return &cobra.Command{Use: "status REQUEST_ID", Short: "Show cards and issue states; exits 5 while an issue is uncertain", Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			raw, err := c.call(cmd, http.MethodGet, "intake/"+url.PathEscape(args[0]), nil, nil)
			if err != nil {
				return err
			}
			return c.printIntake(cmd, raw, true)
		}}
}

func (c *commands) intakeCancel() *cobra.Command {
	var items []string
	cmd := &cobra.Command{Use: "cancel REQUEST_ID [--item ITEM_ID]...", Short: "Cancel the request's unstarted cards (all, or the listed items)", Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			payload := map[string]any{}
			if len(items) > 0 {
				payload["items"] = items
			}
			raw, err := c.call(cmd, http.MethodPost, "intake/"+url.PathEscape(args[0])+"/cancel", nil, payload)
			if err != nil {
				return err
			}
			return c.printIntake(cmd, raw, false)
		}}
	cmd.Flags().StringArrayVar(&items, "item", nil, "Item ID to cancel (repeatable; default all unstarted items)")
	return cmd
}

func (c *commands) intakeResolve() *cobra.Command {
	var action string
	cmd := &cobra.Command{Use: "resolve REQUEST_ID ITEM_ID --action reconcile|abandon", Short: "Reconcile (marker scan, then create) or abandon an unresolved issue intent", Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			if action != "reconcile" && action != "abandon" {
				return errors.New("--action must be reconcile or abandon")
			}
			path := "intake/" + url.PathEscape(args[0]) + "/items/" + url.PathEscape(args[1]) + "/" + action
			raw, err := c.call(cmd, http.MethodPost, path, nil, map[string]any{})
			if err != nil {
				return err
			}
			return c.printIntake(cmd, raw, false)
		}}
	cmd.Flags().StringVar(&action, "action", "", "reconcile or abandon")
	return cmd
}

func (c *commands) printIntake(cmd *cobra.Command, raw json.RawMessage, signalUncertain bool) error {
	var view intakeView
	if err := json.Unmarshal(raw, &view); err != nil {
		return err
	}
	if c.json {
		if _, err := fmt.Fprintln(cmd.OutOrStdout(), string(raw)); err != nil {
			return err
		}
	} else if err := printIntakeTable(cmd.OutOrStdout(), view); err != nil {
		return err
	}
	if signalUncertain {
		for _, item := range view.Intake.Items {
			if item.IssueState == "uncertain" {
				return &intakeUncertain{request: view.Intake.ID}
			}
		}
	}
	return nil
}

func printIntakeTable(w io.Writer, view intakeView) error {
	table := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintf(table, "intake\t%s\tkey=%s\treplayed=%v\n", view.Intake.ID, view.Intake.RequestKey, view.Replayed)
	for _, item := range view.Intake.Items {
		detail := ""
		switch {
		case item.IssueURL != nil:
			detail = *item.IssueURL
		case item.Reason != nil:
			detail = *item.Reason
		case item.LastError != nil:
			detail = *item.LastError
		}
		status := ""
		if item.TaskStatus != nil {
			status = *item.TaskStatus
		}
		fmt.Fprintf(table, "%d\t%s\t%s\t%s\t%s\tissue=%s\t%s\n", item.Position, item.ID, item.TaskID, status, item.Repository, item.IssueState, detail)
	}
	if len(view.Cancelled) > 0 {
		fmt.Fprintf(table, "cancelled\t%s\n", strings.Join(view.Cancelled, ","))
	}
	for _, skipped := range view.Skipped {
		fmt.Fprintf(table, "skipped\t%v\t%v\n", skipped["id"], skipped["reason"])
	}
	if imported := view.Intake.Import; imported != nil {
		for _, skipped := range imported.Skipped {
			card := ""
			if skipped.TaskID != nil {
				card = *skipped.TaskID
			}
			fmt.Fprintf(table, "not imported\t#%d\t%s\t%s\n", skipped.IssueNumber, skipped.Reason, card)
		}
		switch {
		case imported.Bounded && imported.NextPage != nil:
			fmt.Fprintf(table, "listing stopped at its page bound; import again with --start-page %d to continue\n", *imported.NextPage)
		case imported.Bounded:
			fmt.Fprintln(table, "listing stopped at its page bound; import again to continue")
		case imported.NextPage != nil:
			fmt.Fprintf(table, "import again with --start-page %d to continue\n", *imported.NextPage)
		}
	}
	return table.Flush()
}

func readIntakeItems(path string) ([]any, error) {
	raw, err := readBounded(path, intakeFileLimit)
	if err != nil {
		return nil, err
	}
	var items []any
	if err := json.Unmarshal(raw, &items); err != nil || len(items) < 1 || len(items) > 10 {
		return nil, errors.New("items file must be a JSON array of 1-10 item objects")
	}
	return items, nil
}

func readBounded(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot open %s", path)
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(raw)) > limit || !utf8.Valid(raw) {
		return nil, fmt.Errorf("%s must be UTF-8 of at most %d bytes", path, limit)
	}
	return raw, nil
}
