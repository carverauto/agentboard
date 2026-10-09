package cli_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

const fleetCaptain = "fixture-fleet-captain-0123456789abcdef"
const fleetInput = `{"revision":0,"idempotency_key":"configure-example-1","seats":[{"seat_id":"seat-a","agent_id":"worker-a","harness":"codex","desired_host_id":"host-a","desired_model":"unverified-model","desired_effort":"unverified-effort","scope_revision":1}]}`
const fleetResponse = `{"loadout":{"id":"example","revision":1,"enabled":false,"seat_count":1,"seats":[{"seat_id":"seat-a","agent_id":"worker-a","harness":"codex","desired_host_id":"host-a","desired_model":"unverified-model","desired_effort":"unverified-effort","scope_revision":1,"current_scope_revision":1,"scope":{"state":"managed","revision":1},"observed_model":"observed-only","observed_retired_at":null}],"activation_state":"not_activatable","catalog_status":"unverified","host_status":"unverified","changed_by":"captain","updated_at":"2026-10-09T00:00:00Z"},"replayed":false}`

func fleetServer(t *testing.T, schema int, handler http.HandlerFunc) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer "+fleetCaptain || r.Header.Get("X-Agentboard-Worker-Protocol") != "" || r.Header.Get("X-Agentboard-Captain-Token") != "" {
			t.Errorf("wrong captain transport headers on %s", r.URL.Path)
		}
		if r.URL.Path == "/api/v1/meta" {
			fmt.Fprintf(w, `{"api_version":1,"schema_version":%d}`, schema)
			return
		}
		if r.URL.Path != "/api/v1/fleets/example/loadout" {
			t.Errorf("unexpected request %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	token := filepath.Join(t.TempDir(), "captain.token")
	if err := os.WriteFile(token, []byte(fleetCaptain+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENT_ID", "captain")
	t.Setenv("AGENTBOARD_MODEL", "human")
	t.Setenv("AGENTBOARD_HARNESS", "captain")
	// A broken ordinary credential must neither replace nor block the captain.
	t.Setenv("AGENTBOARD_TOKEN", "ordinary-not-captain")
	t.Setenv("AGENTBOARD_TOKEN_FILE", "/nonexistent/ordinary-token")
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", token)
	return token
}

func fleetCommand(args ...string) (string, error) {
	root := cli.NewRoot()
	var output bytes.Buffer
	root.SetOut(&output)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(append([]string{"fleet", "loadout"}, args...))
	err := root.Execute()
	return output.String(), err
}

func fleetFile(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "loadout.json")
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestFleetLoadoutShowUsesCaptainAndRendersDormantState(t *testing.T) {
	for _, jsonMode := range []bool{false, true} {
		t.Run(fmt.Sprint(jsonMode), func(t *testing.T) {
			calls := 0
			fleetServer(t, 35, func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Method != http.MethodGet {
					t.Errorf("unexpected method %s", r.Method)
				}
				fmt.Fprint(w, fleetResponse)
			})
			// Reads require captain authority but do not require write attribution.
			t.Setenv("AGENT_ID", "")
			t.Setenv("AGENTBOARD_MODEL", "")
			t.Setenv("AGENTBOARD_HARNESS", "")
			args := []string{"show", "example"}
			if jsonMode {
				args = append(args, "--json")
			}
			output, err := fleetCommand(args...)
			if err != nil || calls != 1 || strings.Contains(output, fleetCaptain) {
				t.Fatalf("calls %d output %q error %v", calls, output, err)
			}
			for _, want := range []string{`"enabled":false`, `"seat_count":1`, `"activation_state":"not_activatable"`, `"catalog_status":"unverified"`, `"host_status":"unverified"`, `"observed_model":"observed-only"`, "replayed"} {
				if !strings.Contains(output, want) {
					t.Errorf("missing %s in %s", want, output)
				}
			}
			if jsonMode && strings.TrimSpace(output) != fleetResponse {
				t.Errorf("JSON response changed: %s", output)
			}
		})
	}
}

func TestFleetLoadoutSetSendsExactReplacementAndAttribution(t *testing.T) {
	for _, empty := range []bool{false, true} {
		t.Run(fmt.Sprint(empty), func(t *testing.T) {
			body := fleetInput
			if empty {
				body = `{"revision":2,"idempotency_key":"empty-example-3","seats":[]}`
			}
			var want map[string]any
			if err := json.Unmarshal([]byte(body), &want); err != nil {
				t.Fatal(err)
			}
			calls := 0
			fleetServer(t, 35, func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Method != http.MethodPut || r.Header.Get("Content-Type") != "application/json" || r.Header.Get("X-Agentboard-Agent") != "captain" || r.Header.Get("X-Agentboard-Model") != "human" || r.Header.Get("X-Agentboard-Harness") != "captain" {
					t.Error("missing PUT JSON/actor transport")
				}
				var got map[string]any
				if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(got, want) {
					t.Errorf("body %v, want %v", got, want)
				}
				fmt.Fprint(w, fleetResponse)
			})
			// Desired text and keys normalize; no catalog lookup is implied.
			body = strings.ReplaceAll(body, `"unverified-model"`, `" unverified-model "`)
			body = strings.ReplaceAll(body, `"unverified-effort"`, `" unverified-effort "`)
			body = strings.ReplaceAll(body, `"configure-example-1"`, `" configure-example-1 "`)
			output, err := fleetCommand("set", "example", "--file", fleetFile(t, body), "--json")
			if err != nil || calls != 1 || strings.TrimSpace(output) != fleetResponse {
				t.Fatalf("calls %d output %q error %v", calls, output, err)
			}
		})
	}
}

func TestFleetLoadoutRejectsMalformedAndUnknownFieldsBeforeHTTP(t *testing.T) {
	mutate := func(old, replacement string) string { return strings.Replace(fleetInput, old, replacement, 1) }
	cases := map[string]string{
		"empty":              "",
		"invalid-json":       "{",
		"null":               "null",
		"array":              "[]",
		"trailing-json":      fleetInput + " {}",
		"trailing-garbage":   fleetInput + " x",
		"invalid-utf8":       fleetInput + string([]byte{0xff}),
		"too-large":          strings.Repeat(" ", 1<<20) + fleetInput,
		"missing-revision":   mutate(`"revision":0,`, ""),
		"null-revision":      mutate(`"revision":0`, `"revision":null`),
		"negative-revision":  mutate(`"revision":0`, `"revision":-1`),
		"large-revision":     mutate(`"revision":0`, `"revision":2147483647`),
		"fraction-revision":  mutate(`"revision":0`, `"revision":0.5`),
		"string-revision":    mutate(`"revision":0`, `"revision":"0"`),
		"duplicate-revision": mutate(`"revision":0`, `"revision":0,"revision":0`),
		"case-field":         mutate(`"revision":0`, `"Revision":0`),
		"unknown-field":      mutate(`"revision":0`, `"revision":0,"enabled":true`),
		"count-field":        mutate(`"revision":0`, `"revision":0,"seat_count":1`),
		"missing-key":        mutate(`"idempotency_key":"configure-example-1",`, ""),
		"null-key":           mutate(`"configure-example-1"`, "null"),
		"blank-key":          mutate(`"configure-example-1"`, `"  "`),
		"long-key":           mutate(`"configure-example-1"`, `"`+strings.Repeat("k", 129)+`"`),
		"raw-key-bound":      mutate(`"configure-example-1"`, `" `+strings.Repeat("k", 128)+` "`),
		"control-key":        mutate(`"configure-example-1"`, `"key\n"`),
		"missing-seats":      `{"revision":0,"idempotency_key":"key"}`,
		"null-seats":         `{"revision":0,"idempotency_key":"key","seats":null}`,
		"object-seats":       `{"revision":0,"idempotency_key":"key","seats":{}}`,
		"null-seat":          `{"revision":0,"idempotency_key":"key","seats":[null]}`,
		"missing-seat-field": mutate(`"harness":"codex",`, ""),
		"null-seat-field":    mutate(`"harness":"codex"`, `"harness":null`),
		"unknown-seat-field": mutate(`"harness":"codex"`, `"harness":"codex","scope":{}`),
		"duplicate-seat-key": mutate(`"harness":"codex"`, `"harness":"codex","harness":"codex"`),
		"bad-seat-id":        mutate(`"seat-a"`, `"../seat-a"`),
		"bad-agent-id":       mutate(`"worker-a"`, `"Worker-A"`),
		"bad-host-id":        mutate(`"host-a"`, `"host a"`),
		"blank-harness":      mutate(`"codex"`, `" "`),
		"padded-harness":     mutate(`"codex"`, `" codex "`),
		"control-harness":    mutate(`"codex"`, `"codex\t"`),
		"long-harness":       mutate(`"codex"`, `"`+strings.Repeat("h", 129)+`"`),
		"blank-model":        mutate(`"unverified-model"`, `" "`),
		"control-model":      mutate(`"unverified-model"`, `"model\u007f"`),
		"format-model":       mutate(`"unverified-model"`, `"model\u200b"`),
		"long-model":         mutate(`"unverified-model"`, `"`+strings.Repeat("m", 257)+`"`),
		"blank-effort":       mutate(`"unverified-effort"`, `" "`),
		"control-effort":     mutate(`"unverified-effort"`, `"effort\u0000"`),
		"long-effort":        mutate(`"unverified-effort"`, `"`+strings.Repeat("e", 65)+`"`),
		"unmanaged-scope":    mutate(`"scope_revision":1`, `"scope_revision":0`),
		"large-scope":        mutate(`"scope_revision":1`, `"scope_revision":2147483648`),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			// Even schema probing must wait until local file validation succeeds.
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				t.Error("invalid input made an HTTP request")
			}))
			defer server.Close()
			t.Setenv("AGENTBOARD_URL", server.URL)
			output, err := fleetCommand("set", "example", "--file", fleetFile(t, body))
			if err == nil || output != "" || cli.ExitCode(err) != 2 {
				t.Fatalf("invalid file accepted: output %q error %v", output, err)
			}
		})
	}
}

func TestFleetLoadoutSeatLimitAndUniqueness(t *testing.T) {
	for _, scenario := range []string{"too-many", "duplicate-seat", "duplicate-agent"} {
		t.Run(scenario, func(t *testing.T) {
			var input map[string]any
			if err := json.Unmarshal([]byte(fleetInput), &input); err != nil {
				t.Fatal(err)
			}
			seat := input["seats"].([]any)[0].(map[string]any)
			seats := []any{seat}
			count := 2
			if scenario == "too-many" {
				count = 33
			}
			for i := 1; i < count; i++ {
				copy := map[string]any{}
				for key, value := range seat {
					copy[key] = value
				}
				if scenario != "duplicate-seat" {
					copy["seat_id"] = fmt.Sprintf("seat-%d", i)
				}
				if scenario != "duplicate-agent" {
					copy["agent_id"] = fmt.Sprintf("worker-%d", i)
				}
				seats = append(seats, copy)
			}
			input["seats"] = seats
			body, err := json.Marshal(input)
			if err != nil {
				t.Fatal(err)
			}
			output, err := fleetCommand("set", "example", "--file", fleetFile(t, string(body)))
			if err == nil || output != "" {
				t.Fatalf("invalid seats accepted: %q %v", output, err)
			}
		})
	}
}

func TestFleetLoadoutRequiresSchema35(t *testing.T) {
	for _, action := range []string{"show", "set"} {
		t.Run(action, func(t *testing.T) {
			fleetServer(t, 34, func(w http.ResponseWriter, r *http.Request) { t.Error("unsupported endpoint called") })
			args := []string{action, "example"}
			if action == "set" {
				args = append(args, "--file", fleetFile(t, fleetInput))
			}
			output, err := fleetCommand(args...)
			if err == nil || !strings.Contains(err.Error(), "incompatible") || output != "" {
				t.Fatalf("expected schema refusal: %q %v", output, err)
			}
		})
	}
}

func TestFleetLoadoutRequiresProtectedCaptainFileForBothActions(t *testing.T) {
	for _, action := range []string{"show", "set"} {
		for _, mode := range []string{"missing", "public", "symlink"} {
			t.Run(action+"/"+mode, func(t *testing.T) {
				token := fleetServer(t, 35, func(w http.ResponseWriter, r *http.Request) { t.Error("unauthorized endpoint called") })
				switch mode {
				case "missing":
					t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", "")
				case "public":
					if err := os.Chmod(token, 0644); err != nil {
						t.Fatal(err)
					}
				case "symlink":
					link := filepath.Join(t.TempDir(), "token-link")
					if err := os.Symlink(token, link); err != nil {
						t.Fatal(err)
					}
					t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", link)
				}
				args := []string{action, "example"}
				if action == "set" {
					args = append(args, "--file", fleetFile(t, fleetInput))
				}
				output, err := fleetCommand(args...)
				if err == nil || !strings.Contains(err.Error(), "protected captain") || output != "" {
					t.Fatalf("expected protected capability refusal: %q %v", output, err)
				}
			})
		}
	}
}

func TestFleetLoadoutRejectsMissingFileInvalidIDAndCaptainDowngrade(t *testing.T) {
	for _, args := range [][]string{
		{"show", "Example"}, {"show", "example", "--captain=false"},
		{"set", "example"}, {"set", "example", "--file", "/nonexistent/loadout.json"},
		{"set", "../example", "--file", "/nonexistent/loadout.json"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			output, err := fleetCommand(args...)
			if err == nil || output != "" {
				t.Fatalf("invalid invocation accepted: %q %v", output, err)
			}
		})
	}
}

func TestFleetLoadoutConflictIsNotRetried(t *testing.T) {
	calls := 0
	fleetServer(t, 35, func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error":{"code":"conflict","message":"Loadout revision has changed"}}`)
	})
	output, err := fleetCommand("set", "example", "--file", fleetFile(t, fleetInput), "--json")
	if err == nil || cli.ExitCode(err) != 4 || calls != 1 || output != "" {
		t.Fatalf("expected one conflict, got calls %d output %q error %v", calls, output, err)
	}
}

func TestFleetLoadoutSetNeedsNoSelfReportedActorAndPreservesReplay(t *testing.T) {
	replayed := strings.Replace(fleetResponse, `"replayed":false`, `"replayed":true`, 1)
	fleetServer(t, 35, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut || r.Header.Get("X-Agentboard-Agent") != "" || r.Header.Get("X-Agentboard-Model") != "" || r.Header.Get("X-Agentboard-Harness") != "" {
			t.Error("unexpected caller attribution")
		}
		fmt.Fprint(w, replayed)
	})
	t.Setenv("AGENT_ID", "")
	t.Setenv("AGENTBOARD_MODEL", "")
	t.Setenv("AGENTBOARD_HARNESS", "")
	output, err := fleetCommand("set", "example", "--file", fleetFile(t, fleetInput), "--json")
	if err != nil || strings.TrimSpace(output) != replayed {
		t.Fatalf("captain-only exact replay failed: %q %v", output, err)
	}
}
