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

const refillActivation = `{"activation":{"fleet_id":"example","mode":"dry_run","claim_deadline_seconds":900,"revision":1,"changed_by":"captain","activated_at":"2026-10-12T00:00:00Z","updated_at":"2026-10-12T00:00:00Z","refill_enabled":false},"changed":true}`
const refillStatus = `{"refill":{"fleet_id":"example","refill_enabled":true,"activation":{"mode":"dry_run"},"last_pass":{"mode":"dry_run","pairs":[{"task_id":"card-a","agent_id":"seat-a","priority":1,"queue_count":0}],"returned":0,"passed_at":"2026-10-12T00:00:00Z"},"pending":[],"misses":[{"agent_id":"seat-b","count":2,"last_missed_at":"2026-10-12T00:00:00Z","attention":true}]}}`

type refillCall struct {
	method, path string
	body         map[string]any
}

// refillServer is a fake captain API that records each fleet request.
func refillServer(t *testing.T, schema int, status int, response string) *[]refillCall {
	t.Helper()
	calls := &[]refillCall{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer "+fleetCaptain {
			t.Errorf("missing captain bearer on %s", r.URL.Path)
		}
		if r.URL.Path == "/api/v1/meta" {
			fmt.Fprintf(w, `{"api_version":1,"schema_version":%d}`, schema)
			return
		}
		call := refillCall{method: r.Method, path: r.URL.Path}
		if r.Body != nil && r.Method == http.MethodPost {
			if err := json.NewDecoder(r.Body).Decode(&call.body); err != nil {
				t.Errorf("non-JSON body: %v", err)
			}
		}
		*calls = append(*calls, call)
		w.WriteHeader(status)
		fmt.Fprint(w, response)
	}))
	t.Cleanup(server.Close)
	token := filepath.Join(t.TempDir(), "captain.token")
	if err := os.WriteFile(token, []byte(fleetCaptain+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_URL", server.URL)
	// Captain fleet commands need no self-reported actor environment.
	t.Setenv("AGENT_ID", "")
	t.Setenv("AGENTBOARD_MODEL", "")
	t.Setenv("AGENTBOARD_HARNESS", "")
	t.Setenv("AGENTBOARD_TOKEN", "ordinary-not-captain")
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", token)
	return calls
}

func runFleet(args ...string) (string, error) {
	root := cli.NewRoot()
	var output bytes.Buffer
	root.SetOut(&output)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(append([]string{"fleet"}, args...))
	err := root.Execute()
	return output.String(), err
}

func TestFleetActivateSendsModeAndDeadline(t *testing.T) {
	cases := []struct {
		args []string
		want map[string]any
	}{
		{[]string{"activate", "example", "--mode", "dry-run"}, map[string]any{"mode": "dry_run"}},
		{[]string{"activate", "example", "--mode", "live", "--claim-deadline", "15m"}, map[string]any{"mode": "live", "claim_deadline_seconds": float64(900)}},
		{[]string{"deactivate", "example"}, map[string]any{}},
	}
	for _, c := range cases {
		t.Run(strings.Join(c.args, " "), func(t *testing.T) {
			calls := refillServer(t, 46, http.StatusOK, refillActivation)
			output, err := runFleet(append(c.args, "--json")...)
			if err != nil || strings.TrimSpace(output) != refillActivation || strings.Contains(output, fleetCaptain) {
				t.Fatalf("output %q error %v", output, err)
			}
			path := "/api/v1/fleets/example/" + c.args[0]
			if len(*calls) != 1 || (*calls)[0].method != http.MethodPost || (*calls)[0].path != path || !reflect.DeepEqual((*calls)[0].body, c.want) {
				t.Fatalf("calls %+v, want POST %s %v", *calls, path, c.want)
			}
		})
	}
}

func TestFleetRefillStatusReadsDigest(t *testing.T) {
	calls := refillServer(t, 46, http.StatusOK, refillStatus)
	output, err := runFleet("refill", "status", "example")
	if err != nil || len(*calls) != 1 || (*calls)[0].method != http.MethodGet || (*calls)[0].path != "/api/v1/fleets/example/refill" {
		t.Fatalf("calls %+v output %q error %v", *calls, output, err)
	}
	for _, want := range []string{`"card-a"`, `"attention":true`, `"refill_enabled":true`} {
		if !strings.Contains(output, want) {
			t.Errorf("missing %s in %s", want, output)
		}
	}
}

func TestFleetActivateRejectsBadFlagsBeforeHTTP(t *testing.T) {
	for _, args := range [][]string{
		{"activate", "example"},
		{"activate", "example", "--mode", "on"},
		{"activate", "example", "--mode", "dry_run"},
		{"activate", "example", "--mode", "live", "--claim-deadline", "30s"},
		{"activate", "example", "--mode", "live", "--claim-deadline", "25h"},
		{"activate", "example", "--mode", "live", "--claim-deadline", "90500ms"},
		{"activate", "Example", "--mode", "live"},
		{"deactivate", "../example"},
		{"refill", "status", "Example"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			calls := refillServer(t, 46, http.StatusOK, refillActivation)
			output, err := runFleet(args...)
			if err == nil || output != "" || len(*calls) != 0 {
				t.Fatalf("invalid invocation accepted: %q %v %+v", output, err, *calls)
			}
		})
	}
}

func TestFleetRefillCommandsRequireSchema46AndProtectedCaptain(t *testing.T) {
	for _, args := range [][]string{
		{"activate", "example", "--mode", "live"}, {"deactivate", "example"}, {"refill", "status", "example"},
	} {
		t.Run("schema/"+strings.Join(args, " "), func(t *testing.T) {
			calls := refillServer(t, 45, http.StatusOK, refillActivation)
			output, err := runFleet(args...)
			if err == nil || !strings.Contains(err.Error(), "incompatible") || output != "" || len(*calls) != 0 {
				t.Fatalf("expected schema refusal: %q %v", output, err)
			}
		})
		t.Run("captain/"+strings.Join(args, " "), func(t *testing.T) {
			calls := refillServer(t, 46, http.StatusOK, refillActivation)
			t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", "")
			output, err := runFleet(args...)
			if err == nil || !strings.Contains(err.Error(), "protected captain") || output != "" || len(*calls) != 0 {
				t.Fatalf("expected protected capability refusal: %q %v", output, err)
			}
		})
	}
}

func TestFleetActivateConflictIsNotRetried(t *testing.T) {
	calls := refillServer(t, 46, http.StatusConflict, `{"error":{"code":"conflict","message":"Save a fleet loadout before activating it"}}`)
	output, err := runFleet("activate", "example", "--mode", "live")
	if err == nil || cli.ExitCode(err) != 4 || len(*calls) != 1 || output != "" {
		t.Fatalf("expected one conflict, got calls %d output %q error %v", len(*calls), output, err)
	}
}
