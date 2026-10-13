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
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/carverauto/agentboard/internal/config"
	"github.com/spf13/cobra"
)

const fleetLoadoutFileLimit = 1 << 20

type fleetLoadoutInput struct {
	Revision       int64            `json:"revision"`
	IdempotencyKey string           `json:"idempotency_key"`
	Seats          []fleetSeatInput `json:"seats"`
}

type fleetSeatInput struct {
	SeatID        string `json:"seat_id"`
	AgentID       string `json:"agent_id"`
	Harness       string `json:"harness"`
	DesiredHostID string `json:"desired_host_id"`
	DesiredModel  string `json:"desired_model"`
	DesiredEffort string `json:"desired_effort"`
	ScopeRevision int64  `json:"scope_revision"`
}

func (c *commands) fleetCommands() *cobra.Command {
	group := &cobra.Command{Use: "fleet", Short: "Captain-owned fleet configuration, activation, refill and seat supply"}
	loadout := &cobra.Command{Use: "loadout", Short: "Store desired seats without activating workers"}
	show := &cobra.Command{Use: "show FLEET_ID", Short: "Show a dormant loadout using the protected captain capability", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.request(cmd, http.MethodGet, "fleets/"+args[0]+"/loadout", nil, nil)
		}}
	var file string
	set := &cobra.Command{Use: "set FLEET_ID --file PATH", Short: "Replace all desired seats from strict JSON; never activate workers", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if file == "" {
				return errors.New("--file is required")
			}
			input, err := readFleetLoadout(file)
			if err != nil {
				return err
			}
			return c.request(cmd, http.MethodPut, "fleets/"+args[0]+"/loadout", nil, input)
		}}
	set.Flags().StringVar(&file, "file", "", "UTF-8 JSON replacement with revision, idempotency_key and seats (up to 1 MiB)")
	loadout.AddCommand(show, set)
	group.AddCommand(loadout, c.fleetActivateCommand(), c.fleetDeactivateCommand(), c.fleetRefillCommand(), c.fleetSupplyCommand(), c.fleetHostCommand())
	return group
}

func (c *commands) fleetActivateCommand() *cobra.Command {
	var mode string
	var deadline time.Duration
	var requested, maximum int
	cmd := &cobra.Command{Use: "activate FLEET_ID --mode dry-run|live [--claim-deadline DURATION] [--requested-seats N] [--max-seats N]", Short: "Captain: let backlog refill and seat supply use this fleet's seats (dry-run records would-assign pairs and would-launch intents only)", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			payload, err := fleetActivation(mode, deadline, cmd.Flags().Changed("claim-deadline"))
			if err != nil {
				return err
			}
			for flag, value := range map[string]int{"requested-seats": requested, "max-seats": maximum} {
				if !cmd.Flags().Changed(flag) {
					continue
				}
				if value < 0 || value > 32 {
					return fmt.Errorf("--%s must be from 0 to 32", flag)
				}
				payload[strings.ReplaceAll(flag, "-", "_")] = value
			}
			return c.request(cmd, http.MethodPost, "fleets/"+args[0]+"/activate", nil, payload)
		}}
	cmd.Flags().StringVar(&mode, "mode", "", "dry-run (record would-assign pairs and would-launch intents, write nothing else) or live (assign, order and launch)")
	cmd.Flags().DurationVar(&deadline, "claim-deadline", 0, "Return an unclaimed refill assignment to the backlog after this long, 1m to 24h (default 30m on first activation, otherwise unchanged)")
	cmd.Flags().IntVar(&requested, "requested-seats", 0, "Seats seat supply should keep live, 0 to 32 (default 0 on first activation, otherwise unchanged)")
	cmd.Flags().IntVar(&maximum, "max-seats", 0, "Most live seats seat supply may reach, 0 to 32 (default 0 on first activation, otherwise unchanged)")
	return cmd
}

func (c *commands) fleetSupplyCommand() *cobra.Command {
	group := &cobra.Command{Use: "supply", Short: "Inspect seat supply launch intents"}
	status := &cobra.Command{Use: "status FLEET_ID", Short: "Captain: activation seat counts, demand, host enrollment, open and recent launch intents", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.request(cmd, http.MethodGet, "fleets/"+args[0]+"/supply", nil, nil)
		}}
	var reason string
	abandon := &cobra.Command{Use: "abandon FLEET_ID INTENT_ID --reason TEXT", Short: "Captain: close an open launch intent (for example a stuck uncertain one) so its seat can be supplied again", Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			if !config.ValidID(args[0]) {
				return errors.New("FLEET_ID must be a lowercase slug")
			}
			if !fleetText(reason, 500) {
				return errors.New("--reason must be nonblank, control-free text of at most 500 bytes")
			}
			return c.request(cmd, http.MethodPost, "fleets/"+args[0]+"/launch-intents/"+url.PathEscape(args[1])+"/abandon", nil, map[string]any{"reason": reason})
		}}
	abandon.Flags().StringVar(&reason, "reason", "", "Why the intent is abandoned (recorded on it)")
	group.AddCommand(status, abandon)
	return group
}

func (c *commands) fleetHostCommand() *cobra.Command {
	group := &cobra.Command{Use: "host", Short: "Enroll seat-supply hosts"}
	var launchCap int
	var rotate bool
	var tokenFile string
	set := &cobra.Command{Use: "set HOST_ID --launch-cap N [--token-file PATH] [--rotate-token]", Short: "Captain: enroll a host or change its launch cap; a new token is written only to --token-file", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if launchCap < 0 || launchCap > 32 {
				return errors.New("--launch-cap must be from 0 to 32")
			}
			if tokenFile != "" {
				if _, err := os.Lstat(tokenFile); !errors.Is(err, os.ErrNotExist) {
					return errors.New("--token-file must name a new file; move the old token aside first")
				}
			}
			raw, err := c.call(cmd, http.MethodPut, "fleet-hosts/"+args[0], nil, map[string]any{"launch_cap": launchCap, "rotate_token": rotate})
			if err != nil {
				return err
			}
			return c.output(cmd.OutOrStdout(), storeHostToken(raw, tokenFile, cmd))
		}}
	set.Flags().IntVar(&launchCap, "launch-cap", 0, "Launches this host may run at once, 0 to 32 (0 launches nothing)")
	set.Flags().BoolVar(&rotate, "rotate-token", false, "Issue a new token; the old one stops working")
	set.Flags().StringVar(&tokenFile, "token-file", "", "New file (mode 0600) that receives an issued token; required on first enrollment and with --rotate-token")
	_ = set.MarkFlagRequired("launch-cap")
	group.AddCommand(set)
	return group
}

// storeHostToken writes an issued token to tokenFile with mode 0600 and
// removes it from the output, so the token never reaches a terminal or log.
// Without a token file an issued token is withheld and reported as lost.
func storeHostToken(raw json.RawMessage, tokenFile string, cmd *cobra.Command) json.RawMessage {
	var response map[string]json.RawMessage
	if json.Unmarshal(raw, &response) != nil {
		return raw
	}
	encoded, issued := response["token"]
	if !issued {
		return raw
	}
	delete(response, "token")
	var token string
	if json.Unmarshal(encoded, &token) == nil && tokenFile != "" {
		if err := writeNewPrivate(tokenFile, token+"\n"); err == nil {
			response["token_file"], _ = json.Marshal(tokenFile)
		} else {
			fmt.Fprintln(cmd.ErrOrStderr(), "warning: issued token was not stored: "+err.Error()+"; rotate it with --rotate-token --token-file NEW")
		}
	} else {
		fmt.Fprintln(cmd.ErrOrStderr(), "warning: an issued token was withheld because --token-file is unset; rotate it with --rotate-token --token-file PATH")
	}
	out, err := json.Marshal(response)
	if err != nil {
		return raw
	}
	return out
}

func (c *commands) fleetDeactivateCommand() *cobra.Command {
	return &cobra.Command{Use: "deactivate FLEET_ID", Short: "Captain: stop new refill assignments; never releases claims or stops seats", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.request(cmd, http.MethodPost, "fleets/"+args[0]+"/deactivate", nil, map[string]any{})
		}}
}

func (c *commands) fleetRefillCommand() *cobra.Command {
	group := &cobra.Command{Use: "refill", Short: "Inspect deterministic backlog refill"}
	status := &cobra.Command{Use: "status FLEET_ID", Short: "Captain: activation, last pass pairs, pending claim deadlines and per-seat misses", Args: idArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return c.request(cmd, http.MethodGet, "fleets/"+args[0]+"/refill", nil, nil)
		}}
	group.AddCommand(status)
	return group
}

// fleetActivation validates flags before any request. The CLI spells the
// dry-run mode with a hyphen; the API value is dry_run.
func fleetActivation(mode string, deadline time.Duration, deadlineSet bool) (map[string]any, error) {
	payload := map[string]any{}
	switch mode {
	case "dry-run":
		payload["mode"] = "dry_run"
	case "live":
		payload["mode"] = "live"
	default:
		return nil, errors.New("--mode must be dry-run or live")
	}
	if deadlineSet {
		if deadline%time.Second != 0 || deadline < time.Minute || deadline > 24*time.Hour {
			return nil, errors.New("--claim-deadline must be whole seconds from 1m to 24h")
		}
		payload["claim_deadline_seconds"] = int64(deadline / time.Second)
	}
	return payload, nil
}

// writeNewPrivate creates path with mode 0600, refusing an existing file.
func writeNewPrivate(path, text string) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.WriteString(text); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func readFleetLoadout(path string) (fleetLoadoutInput, error) {
	var input fleetLoadoutInput
	file, err := os.Open(path)
	if err != nil {
		return input, errors.New("cannot open loadout file")
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, fleetLoadoutFileLimit+1))
	if err != nil || len(raw) == 0 || len(raw) > fleetLoadoutFileLimit || !utf8.Valid(raw) {
		return input, errors.New("loadout file must be UTF-8 JSON between 1 byte and 1 MiB")
	}
	fields, err := fleetJSONObject(raw, "revision", "idempotency_key", "seats")
	if err != nil {
		return input, fmt.Errorf("invalid loadout JSON: %w", err)
	}
	var seats []json.RawMessage
	if err := json.Unmarshal(fields["seats"], &seats); err != nil || len(seats) > 32 {
		return input, errors.New("seats must be an array of at most 32 seat objects")
	}
	for i, seat := range seats {
		if _, err := fleetJSONObject(seat, "seat_id", "agent_id", "harness", "desired_host_id", "desired_model", "desired_effort", "scope_revision"); err != nil {
			return input, fmt.Errorf("invalid seat %d: %w", i+1, err)
		}
	}
	if err := json.Unmarshal(raw, &input); err != nil {
		return input, errors.New("loadout fields have invalid JSON types")
	}
	if input.Revision < 0 || input.Revision > 2147483646 {
		return input, errors.New("revision must be an integer from 0 to 2147483646")
	}
	if !fleetText(input.IdempotencyKey, 128) {
		return input, errors.New("idempotency_key must be nonblank, control-free text of at most 128 bytes")
	}
	input.IdempotencyKey = strings.TrimSpace(input.IdempotencyKey)
	seatIDs, agentIDs := map[string]bool{}, map[string]bool{}
	for i := range input.Seats {
		seat := &input.Seats[i]
		if !config.ValidID(seat.SeatID) || !config.ValidID(seat.AgentID) || !config.ValidID(seat.DesiredHostID) {
			return input, fmt.Errorf("seat %d requires lowercase seat_id, agent_id and desired_host_id slugs", i+1)
		}
		if seatIDs[seat.SeatID] || agentIDs[seat.AgentID] {
			return input, errors.New("seats must not repeat seat_id or agent_id")
		}
		seatIDs[seat.SeatID], agentIDs[seat.AgentID] = true, true
		if !fleetText(seat.Harness, 128) || strings.TrimSpace(seat.Harness) != seat.Harness {
			return input, fmt.Errorf("seat %d harness must be nonblank, control-free text up to 128 bytes without outer whitespace", i+1)
		}
		if !fleetText(seat.DesiredModel, 256) || !fleetText(seat.DesiredEffort, 64) {
			return input, fmt.Errorf("seat %d desired_model and desired_effort require nonblank, control-free text up to 256 and 64 bytes", i+1)
		}
		seat.DesiredModel = strings.TrimSpace(seat.DesiredModel)
		seat.DesiredEffort = strings.TrimSpace(seat.DesiredEffort)
		if seat.ScopeRevision < 1 || seat.ScopeRevision > 2147483647 {
			return input, fmt.Errorf("seat %d scope_revision must be an integer from 1 to 2147483647", i+1)
		}
	}
	return input, nil
}

// Exact field names, duplicate keys, nulls and trailing JSON are rejected before
// any request. Encoding/json's case-insensitive struct matching is too lenient
// for this full-replacement contract.
func fleetJSONObject(raw []byte, required ...string) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, errors.New("expected a JSON object")
	}
	allowed := map[string]bool{}
	for _, name := range required {
		allowed[name] = true
	}
	fields := map[string]json.RawMessage{}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, errors.New("malformed JSON object")
		}
		name, ok := token.(string)
		if !ok || !allowed[name] {
			return nil, errors.New("unknown JSON field")
		}
		if _, exists := fields[name]; exists {
			return nil, errors.New("duplicate JSON field")
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, errors.New("fields must have valid non-null JSON values")
		}
		fields[name] = value
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, errors.New("malformed JSON object")
	}
	var trailing json.RawMessage
	if decoder.Decode(&trailing) != io.EOF {
		return nil, errors.New("expected exactly one JSON object")
	}
	if len(fields) != len(required) {
		return nil, errors.New("all documented fields are required")
	}
	return fields, nil
}

func fleetText(value string, max int) bool {
	trimmed := strings.TrimSpace(value)
	return trimmed != "" && len(value) <= max && strings.IndexFunc(value, func(r rune) bool {
		return unicode.IsControl(r) || unicode.In(r, unicode.Cf)
	}) == -1
}
