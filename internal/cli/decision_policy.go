package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

const decisionPolicyFileLimit = 256 * 1024
const decisionPolicyProtocolRevision = 1

const decisionPolicyHelp = "Policy evaluation is server-authoritative. File inputs are bounded JSON, not YAML or an offline engine. Plan, explain and validate are read-only. Applying a decision requires explicit exact plan tokens, an active captain-approved version and the server's apply mode. No command enables server mode, provisions credentials or retires a coordinator routine."

func (c *commands) decisionPolicy() *cobra.Command {
	group := c.decisionPolicyPlan("policy")
	group.Short = "Plan server policy decisions by default; inspect or explicitly manage approved versions"
	group.Long = decisionPolicyHelp
	group.AddCommand(c.decisionPolicyPlan("plan"))
	for _, action := range []string{"validate", "draft"} {
		action := action
		var file string
		cmd := &cobra.Command{Use: action + " --file PATH", Short: "Submit a bounded JSON policy for server " + action, Args: cobra.NoArgs}
		cmd.Flags().StringVar(&file, "file", "", "Regular UTF-8 JSON policy file, at most 256 KiB (required)")
		captain := action == "draft"
		if captain {
			decisionPolicyCaptainFlag(cmd)
		}
		cmd.RunE = func(cmd *cobra.Command, _ []string) error {
			if file == "" {
				return errors.New("--file is required")
			}
			policy, err := readDecisionPolicy(file)
			if err != nil {
				return err
			}
			path := "decisions/policy/validate"
			if captain {
				path = "decisions/policy/drafts"
			}
			return c.decisionPolicyRequest(cmd, http.MethodPost, path, nil, map[string]any{"policy": policy}, captain, false)
		}
		group.AddCommand(cmd)
	}
	list := &cobra.Command{Use: "list", Short: "Read retained versions, active state and server mode", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return c.decisionPolicyRequest(cmd, http.MethodGet, "decisions/policy", nil, nil, false, false)
		}}
	show := &cobra.Command{Use: "show POLICY_ID", Short: "Read one immutable policy version by UUID", Args: conversationDecisionIDArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.decisionPolicyRequest(cmd, http.MethodGet, "decisions/policy/versions/"+args[0], nil, nil, false, false)
		}}
	var explainFile string
	explain := &cobra.Command{Use: "explain DECISION_ID", Short: "Read the server's exact evaluation without applying it", Args: conversationDecisionIDArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			body := map[string]any{}
			if cmd.Flags().Changed("file") {
				policy, err := readDecisionPolicy(explainFile)
				if err != nil {
					return err
				}
				body["policy"] = policy
			}
			return c.decisionPolicyRequest(cmd, http.MethodPost, "decisions/policy/explain/"+args[0], nil, body, false, false)
		}}
	explain.Flags().StringVar(&explainFile, "file", "", "Optional bounded JSON policy; omitted uses the server's active policy")
	group.AddCommand(list, show, explain, c.decisionPolicyLedger())
	for _, action := range []string{"approve", "activate"} {
		action := action
		var digest string
		var generation int64
		cmd := &cobra.Command{Use: action + " POLICY_ID", Short: "Captain " + action + " of an exact retained policy digest", Args: conversationDecisionIDArgs}
		decisionPolicyCaptainFlag(cmd)
		cmd.Flags().StringVar(&digest, "sha256", "", "Exact lowercase SHA-256 of the retained version (required)")
		if action == "activate" {
			cmd.Flags().Int64Var(&generation, "generation", -1, "Expected current active-state generation (required)")
		}
		cmd.RunE = func(cmd *cobra.Command, args []string) error {
			if !conversationVersion.MatchString(digest) {
				return errors.New("--sha256 must be an exact lowercase 64-hex SHA-256")
			}
			body := map[string]any{"sha256": digest}
			if action == "activate" {
				if generation < 0 {
					return errors.New("--generation must be a nonnegative integer")
				}
				body["generation"] = generation
			}
			return c.decisionPolicyRequest(cmd, http.MethodPost, "decisions/policy/versions/"+args[0]+"/"+action, nil, body, true, false)
		}
		group.AddCommand(cmd)
	}
	var generation int64
	deactivate := &cobra.Command{Use: "deactivate", Short: "Captain deactivation with exact active-state generation", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if generation < 0 {
				return errors.New("--generation must be a nonnegative integer")
			}
			return c.decisionPolicyRequest(cmd, http.MethodPost, "decisions/policy/deactivate", nil, map[string]any{"generation": generation}, true, false)
		}}
	decisionPolicyCaptainFlag(deactivate)
	deactivate.Flags().Int64Var(&generation, "generation", -1, "Expected current active-state generation (required)")
	group.AddCommand(deactivate, c.decisionPolicyApply())
	return group
}

func (c *commands) decisionPolicyPlan(name string) *cobra.Command {
	var file, cursor string
	var includeClosed bool
	var limit int
	cmd := &cobra.Command{Use: name, Short: "Read a bounded server evaluation page without writes", Args: cobra.NoArgs, Long: decisionPolicyHelp}
	cmd.Flags().StringVar(&file, "file", "", "Optional bounded JSON policy; omitted uses the server's active policy")
	cmd.Flags().StringVar(&cursor, "cursor", "", "Opaque next_cursor from the same query, at most 4096 bytes")
	cmd.Flags().IntVar(&limit, "limit", 20, "Maximum page items, 1–100")
	cmd.Flags().BoolVar(&includeClosed, "include-closed", false, "Include terminal decisions as skipped evaluations")
	cmd.RunE = func(cmd *cobra.Command, _ []string) error {
		if err := decisionPolicyPage(cmd, limit, cursor); err != nil {
			return err
		}
		body := map[string]any{"limit": limit, "include_closed": includeClosed}
		if cursor != "" {
			body["cursor"] = cursor
		}
		if cmd.Flags().Changed("file") {
			policy, err := readDecisionPolicy(file)
			if err != nil {
				return err
			}
			body["policy"] = policy
		}
		return c.decisionPolicyRequest(cmd, http.MethodPost, "decisions/policy/plan", nil, body, false, false)
	}
	return cmd
}

func (c *commands) decisionPolicyLedger() *cobra.Command {
	var decisionID, policyID, cursor string
	var limit int
	cmd := &cobra.Command{Use: "ledger", Short: "Read immutable policy evaluations and answer evidence", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&decisionID, "decision-id", "", "Filter by canonical decision UUID")
	cmd.Flags().StringVar(&policyID, "policy-id", "", "Filter by immutable policy version UUID")
	cmd.Flags().StringVar(&cursor, "cursor", "", "Opaque next_cursor from identical filters, at most 4096 bytes")
	cmd.Flags().IntVar(&limit, "limit", 20, "Maximum page items, 1–100")
	cmd.RunE = func(cmd *cobra.Command, _ []string) error {
		if err := decisionPolicyPage(cmd, limit, cursor); err != nil {
			return err
		}
		query := url.Values{"limit": {strconv.Itoa(limit)}}
		for flag, value := range map[string]string{"decision-id": decisionID, "policy-id": policyID} {
			if cmd.Flags().Changed(flag) {
				if !conversationUUID.MatchString(value) {
					return fmt.Errorf("--%s must be a canonical lowercase UUID", flag)
				}
				query.Set(strings.ReplaceAll(flag, "-", "_"), value)
			}
		}
		if cursor != "" {
			query.Set("cursor", cursor)
		}
		return c.decisionPolicyRequest(cmd, http.MethodGet, "decisions/policy/ledger", query, nil, false, false)
	}
	return cmd
}

func decisionPolicyPage(cmd *cobra.Command, limit int, cursor string) error {
	if limit < 1 || limit > 100 {
		return errors.New("--limit must be 1–100")
	}
	if cmd.Flags().Changed("cursor") && !decisionText(cursor, 4096) {
		return errors.New("--cursor must be nonblank UTF-8 of at most 4096 bytes without NUL")
	}
	return nil
}

func (c *commands) decisionPolicyApply() *cobra.Command {
	var policyID, sourceVersion, day, answerHash string
	var generation int64
	cmd := &cobra.Command{Use: "apply DECISION_ID", Short: "Submit exact read-plan tokens for a captain-authorized server apply", Args: conversationDecisionIDArgs,
		Long: "Submit tokens from a reviewed server plan. This command never reads a new plan or retries with refreshed tokens, and it cannot override active-policy, server-mode, currentness or budget fences.\n\n" + decisionPolicyHelp}
	decisionPolicyCaptainFlag(cmd)
	cmd.Flags().StringVar(&policyID, "policy-id", "", "Exact immutable policy version UUID (required)")
	cmd.Flags().Int64Var(&generation, "generation", -1, "Exact active-state generation from the plan (required)")
	cmd.Flags().StringVar(&sourceVersion, "source-version", "", "Exact lowercase decision-source SHA-256 from the plan (required)")
	cmd.Flags().StringVar(&day, "day", "", "Exact UTC calendar date from the plan, YYYY-MM-DD (required)")
	cmd.Flags().StringVar(&answerHash, "answer-sha256", "", "Exact lowercase proposed-answer SHA-256 from the plan (required)")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if !conversationUUID.MatchString(policyID) || generation < 0 || !conversationVersion.MatchString(sourceVersion) || !conversationVersion.MatchString(answerHash) {
			return errors.New("apply requires --policy-id UUID, nonnegative --generation, and exact lowercase --source-version and --answer-sha256 hashes")
		}
		parsed, err := time.Parse("2006-01-02", day)
		if err != nil || parsed.Format("2006-01-02") != day {
			return errors.New("--day must be a valid exact YYYY-MM-DD date from the plan")
		}
		body := map[string]any{"policy_id": policyID, "generation": generation, "source_version": sourceVersion, "day": day, "answer_sha256": answerHash}
		return c.decisionPolicyRequest(cmd, http.MethodPost, "decisions/policy/apply/"+args[0], nil, body, true, false)
	}
	return cmd
}

func decisionPolicyCaptainFlag(cmd *cobra.Command) {
	cmd.Flags().Bool("captain", true, "Use the protected AGENTBOARD_CAPTAIN_TOKEN_FILE capability (cannot be disabled)")
}

// This transport preserves the entire plan/receipt envelope in both output
// modes. Read-only POSTs do not require write attribution or captain access.
func (c *commands) decisionPolicyRequest(cmd *cobra.Command, method, path string, query url.Values, payload any, captain, attributedWrite bool) error {
	if attributedWrite {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
	}
	var api *client.Client
	var err error
	if captain {
		if enabled, _ := cmd.Flags().GetBool("captain"); !enabled {
			return errors.New("policy changes require the protected captain capability; --captain=false is not supported")
		}
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
		API      int `json:"api_version"`
		Schema   int `json:"schema_version"`
		Protocol int `json:"decision_policy_protocol_revision"`
	}
	if json.Unmarshal(raw, &meta) != nil || meta.API != 1 || meta.Schema < 41 || meta.Protocol != decisionPolicyProtocolRevision {
		return &client.Error{Code: "schema_unavailable", Message: "Decision policy requires schema 41 and advertised decision_policy_protocol_revision 1; an operator must enable a compatible release and run migrations"}
	}
	raw, err = api.JSON(cmd.Context(), method, path, query, payload)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(cmd.OutOrStdout(), string(raw))
	return err
}

func readDecisionPolicy(path string) (json.RawMessage, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("policy file must be a regular JSON file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, errors.New("cannot open policy file")
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
		return nil, errors.New("policy file changed while opening")
	}
	raw, err := io.ReadAll(io.LimitReader(file, decisionPolicyFileLimit+1))
	if err != nil || len(raw) == 0 || len(raw) > decisionPolicyFileLimit || !utf8.Valid(raw) || !json.Valid(raw) || !triageUnicodeValid(raw) {
		return nil, errors.New("policy file must be valid UTF-8 JSON between 1 byte and 256 KiB")
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return nil, errors.New("policy file must contain one JSON object, not YAML or an array")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decisionPolicyJSONValue(decoder, 0); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, errors.New("policy file must contain exactly one JSON object")
	}
	return json.RawMessage(raw), nil
}

// Detect duplicate keys at every nesting level before JSON can silently
// overwrite them. Semantics remain exclusively the server's responsibility.
func decisionPolicyJSONValue(decoder *json.Decoder, depth int) error {
	if depth > 64 {
		return errors.New("policy JSON nesting exceeds 64 levels")
	}
	token, err := decoder.Token()
	if err != nil {
		return errors.New("malformed policy JSON")
	}
	delim, compound := token.(json.Delim)
	if !compound {
		return nil
	}
	if delim != '{' && delim != '[' {
		return errors.New("malformed policy JSON")
	}
	keys := map[string]bool{}
	for decoder.More() {
		if delim == '{' {
			token, err := decoder.Token()
			key, ok := token.(string)
			if err != nil || !ok || keys[key] {
				return errors.New("policy JSON contains a duplicate or invalid object key")
			}
			keys[key] = true
		}
		if err := decisionPolicyJSONValue(decoder, depth+1); err != nil {
			return err
		}
	}
	_, err = decoder.Token()
	if err != nil {
		return errors.New("malformed policy JSON")
	}
	return nil
}
