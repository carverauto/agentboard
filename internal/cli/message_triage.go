package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strconv"
	"unicode/utf8"
)

var (
	triageTaskID = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)
	triageUUID   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

// This is the exact, non-coercing message-triage-v1.schema.json input contract.
// A valid reference is only a claim; the server checks provenance/currentness.
func parseMessageTriage(input string) (json.RawMessage, error) {
	raw := []byte(input)
	invalid := errors.New("--triage must be strict v1 note metadata with valid category, attention, and source fields")
	if len(raw) == 0 || len(raw) > 4096 || !utf8.Valid(raw) || !json.Valid(raw) || !triageUnicodeValid(raw) {
		return nil, errors.New("--triage must be one valid UTF-8 JSON object of at most 4096 bytes")
	}
	fields, ok := triageObject(raw, "version", "category", "attention", "source")
	if !ok || !bytes.Equal(fields["version"], []byte("1")) {
		return nil, invalid
	}
	category, ok := triageString(fields["category"])
	if !ok {
		return nil, invalid
	}
	attention, ok := triageString(fields["attention"])
	if !ok || (attention != "routine" && attention != "captain") {
		return nil, invalid
	}
	var sourceKind string
	var sourceKeys []string
	allowNull := true
	switch category {
	case "status":
		sourceKind, sourceKeys = "task_status", []string{"kind", "task_id", "task_event_id", "task_revision"}
	case "ci", "conflict":
		sourceKind, sourceKeys = "cooperation_event", []string{"kind", "event_id", "source_key"}
		allowNull = false
	case "next_work":
		sourceKind, sourceKeys = "task_assignment", []string{"kind", "task_id", "assignment_revision"}
	case "needs_judgment":
		sourceKind, sourceKeys = "decision_request", []string{"kind", "request_id"}
	default:
		return nil, invalid
	}
	if bytes.Equal(fields["source"], []byte("null")) {
		if allowNull {
			return json.RawMessage(raw), nil
		}
		return nil, invalid
	}
	source, ok := triageObject(fields["source"], sourceKeys...)
	if !ok {
		return nil, invalid
	}
	for key, value := range source {
		switch key {
		case "kind":
			if kind, ok := triageString(value); !ok || kind != sourceKind {
				return nil, invalid
			}
		case "task_id":
			if id, ok := triageString(value); !ok || len(id) > 128 || !triageTaskID.MatchString(id) {
				return nil, invalid
			}
		case "event_id", "request_id":
			if id, ok := triageString(value); !ok || !triageUUID.MatchString(id) {
				return nil, invalid
			}
		case "source_key":
			key, ok := triageString(value)
			if !ok || !triageSourceKey(key) {
				return nil, invalid
			}
		case "task_event_id", "task_revision", "assignment_revision":
			// JSON strings, floats and exponents must not turn into IDs.
			id, err := strconv.ParseInt(string(value), 10, 64)
			if err != nil || id < 1 || id > 9007199254740991 {
				return nil, invalid
			}
		}
	}
	return json.RawMessage(raw), nil
}

// Decode exact required fields without encoding/json's duplicate-key overwrite
// or case-insensitive struct field matching. Null is validated by each field.
func triageObject(raw []byte, required ...string) (map[string]json.RawMessage, bool) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return nil, false
	}
	allowed := make(map[string]bool, len(required))
	for _, key := range required {
		allowed[key] = true
	}
	fields := make(map[string]json.RawMessage, len(required))
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok || !allowed[key] {
			return nil, false
		}
		if _, exists := fields[key]; exists {
			return nil, false
		}
		var value json.RawMessage
		if decoder.Decode(&value) != nil {
			return nil, false
		}
		fields[key] = bytes.TrimSpace(value)
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, false
	}
	var trailing json.RawMessage
	return fields, len(fields) == len(required) && decoder.Decode(&trailing) == io.EOF
}

func triageString(raw []byte) (string, bool) {
	var value string
	if len(raw) == 0 || raw[0] != '"' || json.Unmarshal(raw, &value) != nil {
		return "", false
	}
	return value, true
}

func triageSourceKey(value string) bool {
	if count := utf8.RuneCountInString(value); count < 1 || count > 240 {
		return false
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

// encoding/json silently replaces unpaired UTF-16 surrogates with U+FFFD.
// Reject those inputs rather than changing the claimed canonical source key.
// The caller has already checked JSON syntax and raw UTF-8 validity.
func triageUnicodeValid(raw []byte) bool {
	quoted := false
	for i := 0; i < len(raw); i++ {
		if raw[i] == '"' {
			quoted = !quoted
			continue
		}
		if !quoted || raw[i] != '\\' {
			continue
		}
		i++
		if raw[i] != 'u' {
			continue
		}
		unit, _ := strconv.ParseUint(string(raw[i+1:i+5]), 16, 16)
		i += 4
		if unit >= 0xdc00 && unit <= 0xdfff {
			return false
		}
		if unit >= 0xd800 && unit <= 0xdbff {
			if i+6 >= len(raw) || raw[i+1] != '\\' || raw[i+2] != 'u' {
				return false
			}
			low, _ := strconv.ParseUint(string(raw[i+3:i+7]), 16, 16)
			if low < 0xdc00 || low > 0xdfff {
				return false
			}
			i += 6
		}
	}
	return true
}
