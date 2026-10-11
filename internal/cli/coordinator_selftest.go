package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/spf13/cobra"
)

const selftestPageBytes = 4096

type coordinatorCheck struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Detail string `json:"detail"`
}

type coordinatorSelftestReport struct {
	Version int                `json:"report_version"`
	Mode    string             `json:"mode"`
	Status  string             `json:"status"`
	Checks  []coordinatorCheck `json:"checks"`
}

func (c *commands) coordinatorSelftest() *cobra.Command {
	var offline bool
	cmd := &cobra.Command{
		Use: "selftest", Short: "Check read-only protocol access and local ack fixtures without activating a coordinator", Args: cobra.NoArgs,
		Long: "Check public metadata and one authenticated, bounded attention page. Never sends ack or heartbeat, reads source prose, installs schedules, enrolls an adapter or changes coordinator state. --offline checks synthetic local ack fixtures only. WARN is expected: native scheduling, admission, delivery and received/handled evidence remain unverified. Normal bearer last-use telemetry may apply to reads.",
		// TTL/liveness options have no bearing on this diagnostic. All configuration
		// failures are converted to fixed report text instead of exposing paths.
		PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
		RunE: func(cmd *cobra.Command, _ []string) error {
			report := coordinatorSelftestReport{Version: 1, Mode: "read_only", Status: "PASS", Checks: []coordinatorCheck{}}
			add := func(name, status, detail string) {
				report.Checks = append(report.Checks, coordinatorCheck{name, status, detail})
				if status == "FAIL" || status == "WARN" && report.Status != "FAIL" {
					report.Status = status
				}
			}
			if coordinatorAckFixtures() {
				add("local_ack", "PASS", "Synthetic parser, validation and normalization fixtures passed; no request or receipt was created.")
			} else {
				add("local_ack", "FAIL", "Synthetic ack fixtures failed; do not rely on this client.")
			}
			if offline {
				report.Mode = "offline"
				add("live_protocol", "WARN", "Not checked: offline mode uses no credentials or network.")
			} else {
				c.coordinatorSelftestLive(cmd.Context(), add)
			}
			add("native_schedule", "WARN", "Unverified: no native recurring schedule was inspected or installed.")
			add("native_admission", "WARN", "Unverified: no adapter enrollment or session admission evidence was inspected.")
			add("delivery", "WARN", "Unverified: no notification was sent and no captain delivery was established.")
			add("received_handled", "WARN", "Unverified: no live received/handled receipt or source acknowledgment was established.")
			add("activation", "WARN", "Unverified: this report does not grant conformance, a badge, readiness or permission for cutover.")
			if c.json {
				if err := json.NewEncoder(cmd.OutOrStdout()).Encode(report); err != nil {
					return err
				}
			} else {
				if _, err := fmt.Fprintf(cmd.OutOrStdout(), "%s coordinator selftest (%s)\n", report.Status, report.Mode); err != nil {
					return err
				}
				for _, check := range report.Checks {
					if _, err := fmt.Fprintf(cmd.OutOrStdout(), "%s %s: %s\n", check.Status, check.Name, check.Detail); err != nil {
						return err
					}
				}
			}
			if report.Status == "FAIL" {
				return &client.Error{Code: "selftest_failed", Message: "coordinator selftest failed; see the sanitized report"}
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&offline, "offline", false, "Check synthetic local fixtures only; do not load credentials or contact the API")
	return cmd
}

func (c *commands) coordinatorSelftestLive(ctx context.Context, add func(string, string, string)) {
	if c.cfg.Actor.Validate() != nil || c.cfg.Token == "" && c.cfg.TokenFile == "" {
		add("configuration", "FAIL", "A valid registered actor and explicitly issued coordinator_runner bearer are required; no request was sent.")
		return
	}
	api, err := client.New(c.cfg)
	if err != nil {
		add("configuration", "FAIL", "Cannot initialize protected API transport; check URL, actor and credential configuration privately.")
		return
	}
	defer api.Close()
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	raw, err := api.CoordinatorSelftestRead(ctx, "meta")
	if err != nil {
		add("metadata", "FAIL", "Metadata request failed; check service reachability and configuration privately.")
		return
	}
	if !coordinatorSelftestMeta(raw) {
		add("metadata", "FAIL", "Malformed or incompatible metadata: API 1, schema >=40 and coordinator protocol revision 1 are required.")
		return
	}
	add("metadata", "PASS", "Server advertises API 1, schema >=40 and coordinator protocol revision 1.")
	raw, err = api.CoordinatorSelftestRead(ctx, "coordinator/tick")
	if err != nil {
		detail := "Authenticated tick failed; check service, runner scope and registered attribution privately."
		var apiErr *client.Error
		if errors.As(err, &apiErr) && (apiErr.Status == 401 || apiErr.Status == 403) {
			detail = "Authenticated tick was denied; verify the explicitly issued runner bearer, active coordinator identity and registered attribution privately."
		}
		add("authenticated_tick", "FAIL", detail)
		return
	}
	if !coordinatorSelftestTick(raw, c.cfg.Actor.ID) {
		add("authenticated_tick", "FAIL", "Tick sample failed revision, identity, envelope, item or count/byte budget validation.")
		return
	}
	add("authenticated_tick", "PASS", "One authenticated page matched the configured identity, revision and 1-item/4096-byte bounds; no source content is included in this report.")
	add("pagination", "WARN", "Only the first page was sampled; backlog traversal, snapshot completeness and policy correctness are unverified.")
}

// Reject duplicate keys (including escaped spellings), invalid Unicode and
// excessive nesting before reading fields. Never interpolate remote values.
func selftestJSON(raw []byte, max int) bool {
	if len(raw) > max || !utf8.Valid(raw) || !json.Valid(raw) || !triageUnicodeValid(raw) {
		return false
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	var value func(int) bool
	value = func(depth int) bool {
		if depth > 32 {
			return false
		}
		token, err := dec.Token()
		if err != nil {
			return false
		}
		delim, compound := token.(json.Delim)
		if !compound {
			return true
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for dec.More() {
				keyToken, err := dec.Token()
				key, ok := keyToken.(string)
				if err != nil || !ok || seen[key] {
					return false
				}
				seen[key] = true
				if !value(depth + 1) {
					return false
				}
			}
			end, err := dec.Token()
			return err == nil && end == json.Delim('}')
		case '[':
			for dec.More() {
				if !value(depth + 1) {
					return false
				}
			}
			end, err := dec.Token()
			return err == nil && end == json.Delim(']')
		}
		return false
	}
	if !value(0) {
		return false
	}
	_, err := dec.Token()
	return err == io.EOF
}

func coordinatorSelftestMeta(raw []byte) bool {
	if !selftestJSON(raw, 16384) {
		return false
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return false
	}
	var api, schema, protocol int
	return json.Unmarshal(fields["api_version"], &api) == nil && api == 1 &&
		json.Unmarshal(fields["schema_version"], &schema) == nil && schema >= 40 &&
		json.Unmarshal(fields["coordinator_protocol_revision"], &protocol) == nil && protocol == CoordinatorProtocolRevision
}

func coordinatorSelftestTick(raw []byte, actor string) bool {
	if !selftestJSON(raw, selftestPageBytes) {
		return false
	}
	fields, ok := triageObject(raw, "protocol_revision", "coordinator_id", "items", "complete", "next_cursor", "limits", "restart_from_start", "policy_evaluation")
	if !ok || string(fields["protocol_revision"]) != "1" || string(fields["restart_from_start"]) != "true" {
		return false
	}
	identity, ok := triageString(fields["coordinator_id"])
	if !ok || identity != actor {
		return false
	}
	limits, ok := triageObject(fields["limits"], "limit", "max_bytes")
	if !ok || string(limits["limit"]) != "1" || string(limits["max_bytes"]) != "4096" {
		return false
	}
	policy, ok := triageString(fields["policy_evaluation"])
	if !ok || policy != "server_available" && policy != "not_available" {
		return false
	}
	var items []json.RawMessage
	if len(fields["items"]) == 0 || fields["items"][0] != '[' || json.Unmarshal(fields["items"], &items) != nil || len(items) > 1 {
		return false
	}
	switch string(fields["complete"]) {
	case "true":
		if string(fields["next_cursor"]) != "null" {
			return false
		}
	case "false":
		cursor, ok := triageString(fields["next_cursor"])
		if !ok || !decisionText(cursor, 4096) || len(items) == 0 {
			return false
		}
	default:
		return false
	}
	for _, item := range items {
		var fields map[string]json.RawMessage
		if json.Unmarshal(item, &fields) != nil {
			return false
		}
		id, idOK := triageString(fields["id"])
		version, versionOK := triageString(fields["version"])
		if !idOK || !versionOK || !conversationUUID.MatchString(id) || !conversationVersion.MatchString(version) || string(fields["source_kind"]) != `"decision_request"` || string(fields["status"]) != `"open"` {
			return false
		}
	}
	return true
}

func coordinatorAckFixtures() bool {
	const a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	const b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	version := strings.Repeat("a", 64)
	item := func(id, disposition string) string {
		return fmt.Sprintf(`{"id":%q,"version":%q,"disposition":%q}`, id, version, disposition)
	}
	valid := "[" + item(b, "deferred") + "," + item(a, "reviewed") + "]"
	items, err := parseCoordinatorItems(valid)
	if err != nil || normalizeCoordinatorItems(items) != nil || items[0].ID != a || items[1].ID != b || items[0].Disposition != "reviewed" {
		return false
	}
	for _, input := range []string{"[]", "null", valid + "[]", "[" + item(a, "answered") + "]", "[" + item(a, "reviewed") + "," + item(a, "deferred") + "]", strings.Replace(valid, `"id":`, `"extra":0,"id":`, 1), strings.Replace(valid, `"id":`, `"id":"duplicate","id":`, 1), strings.Replace(valid, version, "invalid-version", 1)} {
		items, err := parseCoordinatorItems(input)
		if err == nil && normalizeCoordinatorItems(items) == nil {
			return false
		}
	}
	return true
}
