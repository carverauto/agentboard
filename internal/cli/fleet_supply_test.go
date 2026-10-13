package cli_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const issuedHostToken = "issued-host-token-0123456789abcdefghijklmnop"

// supplyServer is a fake captain API that records every seat-supply request,
// including PUT bodies.
func supplyServer(t *testing.T, schema int, response string) *[]refillCall {
	t.Helper()
	calls := refillServer(t, schema, http.StatusOK, response)
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
		if r.Method != http.MethodGet {
			if err := json.NewDecoder(r.Body).Decode(&call.body); err != nil {
				t.Errorf("non-JSON body: %v", err)
			}
		}
		*calls = append(*calls, call)
		fmt.Fprint(w, response)
	}))
	t.Cleanup(server.Close)
	t.Setenv("AGENTBOARD_URL", server.URL)
	return calls
}

func TestFleetActivateSendsSeatCountsAtSchema47(t *testing.T) {
	calls := supplyServer(t, 47, refillActivation)
	if _, err := runFleet("activate", "example", "--mode", "live", "--requested-seats", "2", "--max-seats", "3"); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"mode": "live", "requested_seats": float64(2), "max_seats": float64(3)}
	if len(*calls) != 1 || !reflect.DeepEqual((*calls)[0].body, want) {
		t.Fatalf("calls %+v", *calls)
	}
	old := supplyServer(t, 46, refillActivation)
	if _, err := runFleet("activate", "example", "--mode", "live", "--max-seats", "1"); err == nil || !strings.Contains(err.Error(), "incompatible") || len(*old) != 0 {
		t.Fatalf("schema 46 accepted seat counts: %v %+v", err, *old)
	}
	for _, flag := range []string{"--requested-seats=33", "--max-seats=-1"} {
		if _, err := runFleet("activate", "example", "--mode", "live", flag); err == nil {
			t.Fatalf("%s accepted", flag)
		}
	}
}

func TestFleetHostSetStoresTheIssuedTokenPrivately(t *testing.T) {
	response := `{"host":{"host_id":"host-a","launch_cap":1,"revision":1},"changed":true,"token":"` + issuedHostToken + `"}`
	calls := supplyServer(t, 47, response)
	tokenFile := filepath.Join(t.TempDir(), "host-a.token")
	output, err := runFleet("host", "set", "host-a", "--launch-cap", "1", "--token-file", tokenFile, "--json")
	if err != nil || strings.Contains(output, issuedHostToken) || !strings.Contains(output, `"token_file"`) {
		t.Fatalf("output %q error %v", output, err)
	}
	want := map[string]any{"launch_cap": float64(1), "rotate_token": false}
	if len(*calls) != 1 || (*calls)[0].method != http.MethodPut || (*calls)[0].path != "/api/v1/fleet-hosts/host-a" || !reflect.DeepEqual((*calls)[0].body, want) {
		t.Fatalf("calls %+v", *calls)
	}
	info, err := os.Stat(tokenFile)
	stored, _ := os.ReadFile(tokenFile)
	if err != nil || info.Mode().Perm() != 0o600 || strings.TrimSpace(string(stored)) != issuedHostToken {
		t.Fatalf("token file %v %v %q", info, err, stored)
	}
	// An existing token file is never overwritten.
	if _, err := runFleet("host", "set", "host-a", "--launch-cap", "1", "--token-file", tokenFile, "--rotate-token"); err == nil || len(*calls) != 1 {
		t.Fatalf("existing token file accepted: %v", err)
	}
}

func TestFleetSupplyStatusAndAbandon(t *testing.T) {
	calls := supplyServer(t, 47, `{"supply":{"fleet_id":"example"}}`)
	if _, err := runFleet("supply", "status", "example"); err != nil {
		t.Fatal(err)
	}
	if _, err := runFleet("supply", "abandon", "example", "0b6f3c1e-1d2a-4f5b-9c8d-7e6f5a4b3c2d", "--reason", "pane closed by hand"); err != nil {
		t.Fatal(err)
	}
	if len(*calls) != 2 || (*calls)[0].path != "/api/v1/fleets/example/supply" ||
		(*calls)[1].path != "/api/v1/fleets/example/launch-intents/0b6f3c1e-1d2a-4f5b-9c8d-7e6f5a4b3c2d/abandon" ||
		!reflect.DeepEqual((*calls)[1].body, map[string]any{"reason": "pane closed by hand"}) {
		t.Fatalf("calls %+v", *calls)
	}
	if _, err := runFleet("supply", "abandon", "example", "i1", "--reason", " "); err == nil || len(*calls) != 2 {
		t.Fatalf("blank reason accepted: %v", err)
	}
}
