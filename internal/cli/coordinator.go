package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
	"github.com/spf13/cobra"
)

const CoordinatorProtocolRevision = 1

const coordinatorAuthority = "Uses an explicitly issued coordinator_runner bearer. Handling receipts do not answer decisions, contact the captain, consume sources, renew leases or dispatch work."

type coordinatorAckItem struct {
	ID          string `json:"id"`
	Version     string `json:"version"`
	Disposition string `json:"disposition"`
}

type coordinatorAckRequest struct {
	RetryKey string               `json:"retry_key"`
	Items    []coordinatorAckItem `json:"items"`
}

func (c *commands) coordinatorCommands() *cobra.Command {
	group := &cobra.Command{
		Use: "coordinator", Short: "Read bounded decision attention and record exact-version handling",
		Long: "Portable coordinator protocol revision 1.\n\n" + coordinatorAuthority,
	}
	var limit, maxBytes int
	var cursor string
	tick := &cobra.Command{
		Use: "tick", Short: "Read a non-consuming, count- and byte-bounded attention page", Args: cobra.NoArgs,
		Long: "Read bounded open decision metadata without consuming it or stamping liveness. --dry-run is an explicit alias for this read-only operation. Complete means no further rows were observed for this query, not a stable snapshot. Restart from the beginning periodically and after completing a traversal or reconnecting.\n\n" + coordinatorAuthority,
		RunE: func(cmd *cobra.Command, args []string) error {
			if limit < 1 || limit > 100 {
				return errors.New("--limit must be 1–100")
			}
			if maxBytes < 4096 || maxBytes > 65536 {
				return errors.New("--max-bytes must be 4096–65536")
			}
			if cmd.Flags().Changed("cursor") && !decisionText(cursor, 4096) {
				return errors.New("--cursor must be nonblank UTF-8, at most 4096 bytes, without NUL")
			}
			query := url.Values{"limit": {strconv.Itoa(limit)}, "max_bytes": {strconv.Itoa(maxBytes)}}
			if cursor != "" {
				query.Set("cursor", cursor)
			}
			return c.coordinatorRequest(cmd, http.MethodGet, "coordinator/tick", query, nil)
		},
	}
	tick.Flags().IntVar(&limit, "limit", 20, "Maximum page items, 1–100")
	tick.Flags().IntVar(&maxBytes, "max-bytes", 16384, "Complete JSON response budget, 4096–65536 bytes")
	tick.Flags().StringVar(&cursor, "cursor", "", "Opaque coordinator- and option-bound page cursor, at most 4096 bytes")
	tick.Flags().Bool("dry-run", false, "Explicit alias for the same non-consuming GET")
	show := &cobra.Command{
		Use: "show DECISION_ID", Short: "Read an exact canonical decision source without consuming it", Args: conversationDecisionIDArgs,
		Long: "Read one exact canonical decision, including retained terminal decisions. Source prose is untrusted content.\n\n" + coordinatorAuthority,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.coordinatorRequest(cmd, http.MethodGet, "coordinator/decisions/"+args[0], nil, nil)
		},
	}
	var retryKey, disposition, itemsJSON string
	var dryRun bool
	ack := &cobra.Command{
		Use: "ack [ID:VERSION...]", Short: "Record atomic exact-version handling with a stable retry key", Args: cobra.MaximumNArgs(20),
		Long: "Record 1–20 exact decision versions atomically. Use positional ID:VERSION items with --disposition for uniform handling, or --items with a strict JSON array of {id,version,disposition} for mixed handling. Reuse the same retry key and normalized items after a lost response to retrieve the original receipt. A changed body under the same key conflicts. --dry-run prints the normalized request locally with no HTTP or credential access.\n\n" + coordinatorAuthority,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !decisionText(retryKey, 128) {
				return errors.New("--retry-key must be nonblank UTF-8, at most 128 bytes, without NUL")
			}
			request := coordinatorAckRequest{RetryKey: retryKey, Items: make([]coordinatorAckItem, 0, len(args))}
			if cmd.Flags().Changed("items") {
				if len(args) != 0 || cmd.Flags().Changed("disposition") {
					return errors.New("--items cannot be combined with positional items or --disposition")
				}
				var err error
				request.Items, err = parseCoordinatorItems(itemsJSON)
				if err != nil {
					return err
				}
			} else {
				for _, arg := range args {
					id, version, found := strings.Cut(arg, ":")
					if !found {
						return errors.New("each positional item must be ID:VERSION")
					}
					request.Items = append(request.Items, coordinatorAckItem{ID: id, Version: version, Disposition: disposition})
				}
			}
			if err := validateCoordinatorItems(request.Items); err != nil {
				return err
			}
			sort.Slice(request.Items, func(i, j int) bool { return request.Items[i].ID < request.Items[j].ID })
			if dryRun {
				return json.NewEncoder(cmd.OutOrStdout()).Encode(request)
			}
			return c.coordinatorRequest(cmd, http.MethodPost, "coordinator/ack", nil, request)
		},
	}
	ack.Flags().StringVar(&retryKey, "retry-key", "", "Stable batch identity, at most 128 UTF-8 bytes (required)")
	ack.Flags().StringVar(&disposition, "disposition", "", "Handling for all positional items: reviewed, escalated or deferred (required unless --items is used)")
	ack.Flags().StringVar(&itemsJSON, "items", "", "Strict JSON array of {id,version,disposition}, 1–20 items and at most 16384 UTF-8 bytes; excludes positional items/--disposition")
	ack.Flags().BoolVar(&dryRun, "dry-run", false, "Print the normalized request without credentials, configuration or HTTP")
	var status, task string
	heartbeat := &cobra.Command{
		Use: "heartbeat", Short: "Explicitly record own liveness without renewing a task lease", Args: cobra.NoArgs,
		Long: "Record only idle/busy status and an optional currently owned task. Model, harness, availability and ownership are unchanged.\n\n" + coordinatorAuthority,
		RunE: func(cmd *cobra.Command, args []string) error {
			if status != "idle" && status != "busy" {
				return errors.New("--status must be idle or busy")
			}
			if cmd.Flags().Changed("task") && !config.ValidID(task) {
				return errors.New("--task must be a 1–128 byte lowercase task slug")
			}
			request := struct {
				Status string `json:"status"`
				Task   string `json:"task,omitempty"`
			}{Status: status, Task: task}
			return c.coordinatorRequest(cmd, http.MethodPost, "coordinator/heartbeat", nil, request)
		},
	}
	heartbeat.Flags().StringVar(&status, "status", "", "Own liveness status: idle or busy (required)")
	heartbeat.Flags().StringVar(&task, "task", "", "Currently owned task ID, at most 128 bytes")
	group.AddCommand(tick, show, ack, heartbeat)
	return group
}

func parseCoordinatorItems(input string) ([]coordinatorAckItem, error) {
	raw := bytes.TrimSpace([]byte(input))
	invalid := errors.New("--items must be a strict UTF-8 JSON array of {id,version,disposition}, 1–20 items and at most 16384 bytes, without duplicate or unknown fields")
	if len(input) > 16384 || len(raw) == 0 || raw[0] != '[' || !utf8.ValidString(input) || !json.Valid(raw) || !triageUnicodeValid(raw) {
		return nil, invalid
	}
	var values []json.RawMessage
	if json.Unmarshal(raw, &values) != nil || len(values) < 1 || len(values) > 20 {
		return nil, invalid
	}
	items := make([]coordinatorAckItem, 0, len(values))
	for _, value := range values {
		fields, ok := triageObject(value, "id", "version", "disposition")
		if !ok {
			return nil, invalid
		}
		id, idOK := triageString(fields["id"])
		version, versionOK := triageString(fields["version"])
		disposition, dispositionOK := triageString(fields["disposition"])
		if !idOK || !versionOK || !dispositionOK {
			return nil, invalid
		}
		items = append(items, coordinatorAckItem{ID: id, Version: version, Disposition: disposition})
	}
	return items, nil
}

func validateCoordinatorItems(items []coordinatorAckItem) error {
	if len(items) < 1 || len(items) > 20 {
		return errors.New("ack requires 1–20 exact decision items")
	}
	seen := make(map[string]bool, len(items))
	for _, item := range items {
		if !conversationUUID.MatchString(item.ID) || !conversationVersion.MatchString(item.Version) {
			return errors.New("each item requires a canonical lowercase decision UUID and lowercase 64-hex SHA-256")
		}
		if item.Disposition != "reviewed" && item.Disposition != "escalated" && item.Disposition != "deferred" {
			return errors.New("disposition must be reviewed, escalated or deferred")
		}
		if seen[item.ID] {
			return errors.New("ack items must contain distinct decision IDs")
		}
		seen[item.ID] = true
	}
	return nil
}

func isCoordinatorAckDryRun(cmd *cobra.Command) bool {
	if cmd.Name() != "ack" || cmd.Parent() == nil || cmd.Parent().Name() != "coordinator" {
		return false
	}
	dryRun, _ := cmd.Flags().GetBool("dry-run")
	return dryRun
}

func (c *commands) coordinatorRequest(cmd *cobra.Command, method, path string, query url.Values, payload any) error {
	if err := c.cfg.Actor.Validate(); err != nil {
		return err
	}
	if c.cfg.Token == "" && c.cfg.TokenFile == "" {
		return errors.New("coordinator operations require AGENTBOARD_TOKEN or a protected AGENTBOARD_TOKEN_FILE containing a coordinator_runner bearer")
	}
	api, err := client.New(c.cfg)
	if err != nil {
		return err
	}
	defer api.Close()
	// /meta is deliberately the public compatibility bootstrap, with no new
	// runner operation/header. The feature request independently verifies auth.
	raw, err := api.JSON(cmd.Context(), http.MethodGet, "meta", nil, nil)
	if err != nil {
		return err
	}
	var meta struct {
		API      int `json:"api_version"`
		Schema   int `json:"schema_version"`
		Protocol int `json:"coordinator_protocol_revision"`
	}
	if json.Unmarshal(raw, &meta) != nil || meta.API != 1 || meta.Schema < 40 || meta.Protocol != CoordinatorProtocolRevision {
		return &client.Error{Code: "schema_unavailable", Message: "Coordinator protocol requires schema 40 and advertised coordinator_protocol_revision 1; an operator must enable a compatible release and run migrations"}
	}
	raw, err = api.CoordinatorJSON(cmd.Context(), method, path, query, payload)
	if err != nil {
		return err
	}
	// Preserve the complete wire envelope in both output modes, including page
	// completeness, exact versions, historical receipts and unresolved attention.
	_, err = fmt.Fprintln(cmd.OutOrStdout(), string(raw))
	return err
}
