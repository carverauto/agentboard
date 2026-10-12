package cli_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

const selftestTick = `{"protocol_revision":1,"coordinator_id":"fixture-coordinator","items":[],"complete":true,"next_cursor":null,"limits":{"limit":1,"max_bytes":4096},"restart_from_start":true,"policy_evaluation":"server_available"}`

type selftestReport struct {
	Version      int `json:"report_version"`
	Mode, Status string
	Checks       []struct{ Name, Status, Detail string }
}

func readSelftestReport(t *testing.T, out string) selftestReport {
	t.Helper()
	var report selftestReport
	if json.Unmarshal([]byte(out), &report) != nil || report.Version != 1 {
		t.Fatalf("invalid report: %s", out)
	}
	for _, name := range []string{"native_schedule", "native_admission", "delivery", "received_handled", "activation"} {
		found := false
		for _, check := range report.Checks {
			if check.Name == name && check.Status == "WARN" {
				found = true
			}
		}
		if !found {
			t.Fatalf("missing unverified evidence: %s", name)
		}
	}
	if report.Status == "PASS" {
		t.Fatal("partial selftest claimed complete live conformance")
	}
	return report
}

func TestCoordinatorSelftestReadOnly(t *testing.T) {
	for _, body := range []string{selftestTick, strings.Replace(strings.Replace(selftestTick, `"items":[]`, `"items":[{"id":"`+coordinatorDecisionA+`","version":"`+coordinatorVersion+`","source_kind":"decision_request","status":"open","question":"secret-source-prose"}]`, 1), `"complete":true,"next_cursor":null`, `"complete":false,"next_cursor":"opaque-sample-cursor"`, 1)} {
		calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodGet || r.URL.Path != "/api/v1/coordinator/tick" || r.URL.RawQuery != "limit=1&max_bytes=4096" || r.ContentLength > 0 {
				t.Errorf("unexpected request: %s %s", r.Method, r.URL)
			}
			fmt.Fprint(w, body)
		})
		out, stderr, err := coordinatorCommand("selftest", "--json")
		if err != nil || stderr != "" || calls.Load() != 2 {
			t.Fatalf("calls %d err %v stderr %s", calls.Load(), err, stderr)
		}
		report := readSelftestReport(t, out)
		if report.Status != "WARN" || report.Mode != "read_only" {
			t.Fatalf("incorrect success: %+v", report)
		}
		for _, name := range []string{"local_ack", "metadata", "authenticated_tick"} {
			found := false
			for _, check := range report.Checks {
				if check.Name == name && check.Status == "PASS" {
					found = true
				}
			}
			if !found {
				t.Fatalf("missing successful check %s", name)
			}
		}
		for _, secret := range []string{coordinatorBearer, "secret-source-prose", "opaque-sample-cursor", coordinatorDecisionA, coordinatorVersion} {
			if strings.Contains(out+stderr, secret) {
				t.Fatalf("report disclosed response data %s", secret)
			}
		}
	}
}

func TestCoordinatorSelftestOfflineNoConfigurationOrNetwork(t *testing.T) {
	calls := coordinatorServer(t, coordinatorMeta, func(http.ResponseWriter, *http.Request) { t.Error("offline request") })
	for key, value := range map[string]string{"AGENTBOARD_URL": "bad URL", "AGENTBOARD_TOKEN": "bad token", "AGENTBOARD_TOKEN_FILE": "/secret/credential-path", "AGENTBOARD_CA_FILE": "/secret/ca-path", "AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE": "/secret/access-path", "AGENT_ID": "bad/actor", "AGENTBOARD_MODEL": "", "AGENTBOARD_HARNESS": "", "AGENTBOARD_CLAIM_TTL": "bad", "AGENTBOARD_STALE_AFTER": "bad"} {
		t.Setenv(key, value)
	}
	out, stderr, err := coordinatorCommand("selftest", "--offline", "--json")
	if err != nil || stderr != "" || calls.Load() != 0 {
		t.Fatalf("calls %d err %v stderr %s", calls.Load(), err, stderr)
	}
	report := readSelftestReport(t, out)
	if report.Status != "WARN" || report.Mode != "offline" {
		t.Fatalf("incorrect offline report: %+v", report)
	}
	if strings.Contains(out, "/secret/") {
		t.Fatal("credential path disclosed")
	}
}

func TestCoordinatorSelftestFailsClosedOnResponses(t *testing.T) {
	cases := map[string]string{
		"empty": "{}", "null": "null", "array": "[]", "bad-json": "{", "revision": strings.Replace(selftestTick, `"protocol_revision":1`, `"protocol_revision":2`, 1),
		"wrong-identity":            strings.Replace(selftestTick, "fixture-coordinator", "some-other-coordinator", 1),
		"duplicate-identity":        strings.Replace(selftestTick, `"coordinator_id":`, `"coordinator_id":"wrong","coordinator_id":`, 1),
		"missing-identity":          strings.Replace(selftestTick, `"coordinator_id":"fixture-coordinator",`, "", 1),
		"null-items":                strings.Replace(selftestTick, `"items":[]`, `"items":null`, 1),
		"bad-item":                  strings.Replace(selftestTick, `"items":[]`, `"items":[{}]`, 1),
		"too-many":                  strings.Replace(selftestTick, `"items":[]`, `"items":[{},{}]`, 1),
		"wrong-limits":              strings.Replace(selftestTick, `"limit":1`, `"limit":20`, 1),
		"missing-complete":          strings.Replace(selftestTick, `"complete":true,`, "", 1),
		"missing-cursor":            strings.Replace(selftestTick, `"next_cursor":null,`, "", 1),
		"null-complete":             strings.Replace(selftestTick, `"complete":true`, `"complete":null`, 1),
		"incomplete-empty":          strings.Replace(selftestTick, `"complete":true`, `"complete":false`, 1),
		"complete-cursor":           strings.Replace(selftestTick, `"next_cursor":null`, `"next_cursor":"source-prose"`, 1),
		"oversized":                 selftestTick + strings.Repeat(" ", 4096),
		"unicode":                   strings.Replace(selftestTick, "server_available", `\ud800`, 1),
		"reflected-invalid-unicode": strings.Replace(selftestTick, `"items":[]`, `"items":[{"id":"`+coordinatorDecisionA+`","version":"`+coordinatorVersion+`","source_kind":"decision_request","status":"open","extra":"`+coordinatorBearer+`\ud800"}]`, 1),
		"invalid-utf8":              strings.Replace(selftestTick, "server_available", string([]byte{0xff}), 1),
		"duplicate-nested":          strings.Replace(selftestTick, `"limit":1`, `"limit":1,"limit":1`, 1),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet {
					t.Fatal("mutation")
				}
				fmt.Fprint(w, body)
			})
			out, _, err := coordinatorCommand("selftest", "--json")
			if err == nil || calls.Load() != 2 || readSelftestReport(t, out).Status != "FAIL" {
				t.Fatalf("accepted %s: %s err %v", name, out, err)
			}
		})
	}
}

func TestCoordinatorSelftestMetadataFailStopsTick(t *testing.T) {
	for _, meta := range []string{`{}`, `null`, strings.Replace(coordinatorMeta, `"schema_version":40`, `"schema_version":39`, 1), strings.Replace(coordinatorMeta, `"api_version":1`, `"api_version":2`, 1), strings.Replace(coordinatorMeta, `"coordinator_protocol_revision":1`, `"coordinator_protocol_revision":2`, 1), strings.Replace(coordinatorMeta, `"api_version":1`, `"api_version":2,"api_version":1`, 1), coordinatorMeta + strings.Repeat(" ", 16384)} {
		calls := coordinatorServer(t, meta, func(http.ResponseWriter, *http.Request) { t.Error("incompatible meta reached tick") })
		out, _, err := coordinatorCommand("selftest", "--json")
		if err == nil || calls.Load() != 1 || readSelftestReport(t, out).Status != "FAIL" {
			t.Fatalf("metadata accepted err %v calls %d", err, calls.Load())
		}
	}
}

func TestCoordinatorSelftestSanitizesErrors(t *testing.T) {
	for _, status := range []int{401, 403, 404, 409, 422} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(status)
				fmt.Fprintf(w, `{"error":{"code":"/private/credential-file","message":"source-secret %s"}}`, coordinatorBearer)
			})
			out, stderr, err := coordinatorCommand("selftest", "--json")
			if err == nil || calls.Load() != 2 || readSelftestReport(t, out).Status != "FAIL" {
				t.Fatal("denial accepted")
			}
			combined := out + stderr + err.Error()
			for _, secret := range []string{coordinatorBearer, "/private/credential-file", "source-secret"} {
				if strings.Contains(combined, secret) {
					t.Fatal("error leaked remote content")
				}
			}
		})
	}
	for key, value := range map[string]string{"AGENTBOARD_TOKEN": "", "AGENTBOARD_TOKEN_FILE": "/private/credential-file", "AGENTBOARD_CA_FILE": "/private/ca-file", "AGENTBOARD_URL": "https://name:secret@example.com", "AGENT_ID": "invalid/actor"} {
		t.Run(key, func(t *testing.T) {
			calls := coordinatorServer(t, coordinatorMeta, func(http.ResponseWriter, *http.Request) { t.Error("invalid config reached tick") })
			if key == "AGENTBOARD_TOKEN_FILE" {
				t.Setenv("AGENTBOARD_TOKEN", "")
			}
			t.Setenv(key, value)
			out, stderr, err := coordinatorCommand("selftest", "--json")
			if err == nil || calls.Load() != 0 || readSelftestReport(t, out).Status != "FAIL" {
				t.Fatal("invalid configuration accepted")
			}
			if strings.Contains(out+stderr+err.Error(), "/private/") || strings.Contains(out+stderr+err.Error(), "name:secret") {
				t.Fatal("configuration leaked")
			}
		})
	}
}

func TestCoordinatorSelftestPlainReport(t *testing.T) {
	out, stderr, err := coordinatorCommand("selftest", "--offline")
	if err != nil || stderr != "" || !strings.HasPrefix(out, "WARN coordinator selftest (offline)\nPASS local_ack:") || !strings.Contains(out, "WARN received_handled:") {
		t.Fatalf("plain report %s %s %v", out, stderr, err)
	}
}
