package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
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
	group := &cobra.Command{Use: "fleet", Short: "Captain-owned dormant fleet configuration"}
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
	group.AddCommand(loadout)
	return group
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
