package cli_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
	"github.com/carverauto/agentboard/internal/client"
)

const (
	coordinatorDecisionA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	coordinatorDecisionB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	coordinatorVersion   = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	coordinatorBearer    = "synthetic-runner-bearer-0123456789abcdef"
	coordinatorMeta      = `{"api_version":1,"schema_version":40,"coordinator_protocol_revision":1}`
)

type coordinatorCommandCase struct {
	name, method, path, response string
	args                         []string
	query                        url.Values
	payload                      string
}

func coordinatorCommandCases() []coordinatorCommandCase {
	return []coordinatorCommandCase{
		{name: "tick", method: http.MethodGet, path: "coordinator/tick", args: []string{"tick"}, query: url.Values{"limit": {"20"}, "max_bytes": {"16384"}}, response: `{"protocol_revision":1,"items":[],"next_cursor":null,"complete":true}`},
		{name: "tick-options", method: http.MethodGet, path: "coordinator/tick", args: []string{"tick", "--limit", "100", "--max-bytes", "65536", "--cursor", "opaque+/=?&cursor", "--dry-run"}, query: url.Values{"limit": {"100"}, "max_bytes": {"65536"}, "cursor": {"opaque+/=?&cursor"}}, response: `{"protocol_revision":1,"items":[{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `","attention_state":"captain_pending","policy_evaluation":"not_available"}],"next_cursor":"opaque-next","complete":false}`},
		{name: "show", method: http.MethodGet, path: "coordinator/decisions/" + coordinatorDecisionA, args: []string{"show", coordinatorDecisionA}, response: `{"protocol_revision":1,"decision":{"id":"` + coordinatorDecisionA + `","status":"answered","question":"Untrusted source: α <>&"},"attention":null}`},
		{name: "ack", method: http.MethodPost, path: "coordinator/ack", args: []string{"ack", coordinatorDecisionB + ":" + coordinatorVersion, coordinatorDecisionA + ":" + coordinatorVersion, "--retry-key", " Keep exact key: α <>& ", "--disposition", "escalated"}, payload: `{"retry_key":" Keep exact key: α <>& ","items":[{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `","disposition":"escalated"},{"id":"` + coordinatorDecisionB + `","version":"` + coordinatorVersion + `","disposition":"escalated"}]}`, response: `{"protocol_revision":1,"receipt":{"id":"fixture-batch","retry_key":"fixture-retry","actor_id":"fixture-coordinator","items":[{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `","disposition":"escalated"}],"created_at":"2026-10-10T00:00:00Z"},"replayed":true}`},
		{name: "heartbeat-idle", method: http.MethodPost, path: "coordinator/heartbeat", args: []string{"heartbeat", "--status", "idle"}, payload: `{"status":"idle"}`, response: `{"protocol_revision":1,"agent":{"id":"fixture-coordinator","status":"idle"}}`},
		{name: "heartbeat-task", method: http.MethodPost, path: "coordinator/heartbeat", args: []string{"heartbeat", "--status", "busy", "--task", "work-123_abc"}, payload: `{"status":"busy","task":"work-123_abc"}`, response: `{"protocol_revision":1,"agent":{"id":"fixture-coordinator","status":"busy","current_task":"work-123_abc"}}`},
	}
}

func coordinatorServer(t *testing.T, metadata string, handler http.HandlerFunc) *atomic.Int32 {
	t.Helper()
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer "+coordinatorBearer {
			t.Error("coordinator request did not use ordinary bearer")
		}
		for _, name := range []string{"X-Agentboard-Captain-Token", "X-Agentboard-Worker-Protocol"} {
			if r.Header.Get(name) != "" {
				t.Errorf("unexpected protected header %s", name)
			}
		}
		if r.URL.Path == "/api/v1/meta" {
			if r.Method != http.MethodGet || r.URL.RawQuery != "" || r.Header.Get("X-Agentboard-Coordinator-Protocol") != "" {
				t.Errorf("changed public metadata bootstrap: %s %s", r.Method, r.URL)
			}
			fmt.Fprint(w, metadata)
			return
		}
		if r.Header.Get("X-Agentboard-Coordinator-Protocol") != "1" {
			t.Error("coordinator request missing protocol revision")
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_TOKEN", coordinatorBearer)
	t.Setenv("AGENTBOARD_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_CA_FILE", "")
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", filepath.Join(t.TempDir(), "must-not-be-read"))
	t.Setenv("AGENT_ID", "fixture-coordinator")
	t.Setenv("AGENTBOARD_MODEL", "fixture-model")
	t.Setenv("AGENTBOARD_HARNESS", "codex")
	t.Setenv("AGENTBOARD_CLAIM_TTL", "")
	t.Setenv("AGENTBOARD_STALE_AFTER", "")
	return &calls
}

func coordinatorCommand(args ...string) (string, string, error) {
	root := cli.NewRoot()
	var out, stderr bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&stderr)
	root.SetArgs(append([]string{"coordinator"}, args...))
	err := root.Execute()
	return out.String(), stderr.String(), err
}

func TestCoordinatorExactTransportAndJSONParity(t *testing.T) {
	for _, tc := range coordinatorCommandCases() {
		for _, jsonMode := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/json-%v", tc.name, jsonMode), func(t *testing.T) {
				calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) {
					if r.Method != tc.method || r.URL.Path != "/api/v1/"+tc.path || r.URL.RawQuery != tc.query.Encode() {
						t.Errorf("unexpected operation %s %s", r.Method, r.URL)
					}
					for name, want := range map[string]string{"X-Agentboard-Agent": "fixture-coordinator", "X-Agentboard-Model": "fixture-model", "X-Agentboard-Harness": "codex"} {
						if r.Header.Get(name) != want {
							t.Errorf("incorrect attribution %s", name)
						}
					}
					body, err := io.ReadAll(r.Body)
					if err != nil {
						t.Fatal(err)
					}
					if tc.payload == "" {
						if len(body) != 0 {
							t.Error("read sent a request body")
						}
					} else {
						var got, want any
						if json.Unmarshal(body, &got) != nil || json.Unmarshal([]byte(tc.payload), &want) != nil || !reflect.DeepEqual(got, want) {
							t.Errorf("request body changed: got %s want %s", body, tc.payload)
						}
					}
					fmt.Fprint(w, tc.response)
				})
				args := append([]string(nil), tc.args...)
				if jsonMode {
					args = append(args, "--json")
				}
				out, stderr, err := coordinatorCommand(args...)
				if err != nil || stderr != "" || calls.Load() != 2 || out != tc.response+"\n" {
					t.Fatalf("requests %d output %q stderr %q error %v", calls.Load(), out, stderr, err)
				}
			})
		}
	}
}

func TestCoordinatorAckDryRunHasNoConfigurationOrHTTPDependency(t *testing.T) {
	calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) { t.Error("dry-run reached HTTP") })
	for key, value := range map[string]string{
		"AGENTBOARD_URL": "not a URL", "AGENTBOARD_TOKEN": "bad token", "AGENTBOARD_TOKEN_FILE": "/missing-bearer",
		"AGENTBOARD_CA_FILE": "/missing-ca", "AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE": "/missing-access",
		"AGENT_ID": "bad/actor", "AGENTBOARD_MODEL": "", "AGENTBOARD_HARNESS": "",
		"AGENTBOARD_CLAIM_TTL": "bad-duration", "AGENTBOARD_STALE_AFTER": "bad-duration",
	} {
		t.Setenv(key, value)
	}
	for _, disposition := range []string{"reviewed", "escalated", "deferred"} {
		args := []string{"ack", coordinatorDecisionB + ":" + coordinatorVersion, coordinatorDecisionA + ":" + coordinatorVersion, "--retry-key", "fixture-retry", "--disposition", disposition, "--dry-run"}
		out, stderr, err := coordinatorCommand(args...)
		want := `{"retry_key":"fixture-retry","items":[{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `","disposition":"` + disposition + `"},{"id":"` + coordinatorDecisionB + `","version":"` + coordinatorVersion + `","disposition":"` + disposition + `"}]}` + "\n"
		if err != nil || stderr != "" || out != want || calls.Load() != 0 {
			t.Fatalf("requests %d output %q stderr %q error %v", calls.Load(), out, stderr, err)
		}
	}
}

func TestCoordinatorInvalidInputPrecedesHTTP(t *testing.T) {
	item := coordinatorDecisionA + ":" + coordinatorVersion
	cases := map[string][]string{
		"tick-extra": {"tick", "extra"}, "tick-zero": {"tick", "--limit", "0"}, "tick-negative": {"tick", "--limit", "-1"}, "tick-high": {"tick", "--limit", "101"}, "tick-float": {"tick", "--limit", "1.5"},
		"bytes-low": {"tick", "--max-bytes", "4095"}, "bytes-high": {"tick", "--max-bytes", "65537"},
		"show-missing": {"show"}, "show-extra": {"show", coordinatorDecisionA, coordinatorDecisionB},
		"ack-empty": {"ack", "--retry-key", "key", "--disposition", "reviewed"}, "ack-missing-key": {"ack", item, "--disposition", "reviewed"}, "ack-missing-disposition": {"ack", item, "--retry-key", "key"},
		"ack-duplicate":                   {"ack", item, item, "--retry-key", "key", "--disposition", "reviewed"},
		"ack-duplicate-different-version": {"ack", item, coordinatorDecisionA + ":" + strings.Repeat("f", 64), "--retry-key", "key", "--disposition", "reviewed"},
		"ack-extra-colon":                 {"ack", item + ":reviewed", "--retry-key", "key", "--disposition", "reviewed"},
		"heartbeat-no-status":             {"heartbeat"}, "heartbeat-bad-status": {"heartbeat", "--status", "offline"}, "heartbeat-extra": {"heartbeat", "extra", "--status", "idle"},
	}
	for name, value := range map[string]string{"empty": "", "blank": " \t\n", "unicode-blank": "\u2003", "nul": "a\x00b", "invalid-utf8": string([]byte{0xff}), "too-long": strings.Repeat("x", 4097)} {
		cases["cursor-"+name] = []string{"tick", "--cursor", value}
	}
	for name, value := range map[string]string{"empty": "", "blank": " \t\n", "unicode-blank": "\u2003", "nul": "a\x00b", "invalid-utf8": string([]byte{0xff}), "too-long": strings.Repeat("x", 129), "unicode-over": strings.Repeat("🙂", 32) + "x"} {
		cases["retry-key-"+name] = []string{"ack", item, "--retry-key", value, "--disposition", "reviewed", "--dry-run"}
	}
	for name, value := range map[string]string{"empty": "", "uppercase": strings.ToUpper(coordinatorDecisionA), "short": "abc", "compact": strings.ReplaceAll(coordinatorDecisionA, "-", ""), "path": coordinatorDecisionA + "/answer", "newline": coordinatorDecisionA + "\n", "nonhex": strings.Repeat("g", 36), "invalid-utf8": string([]byte{0xff})} {
		cases["show-id-"+name] = []string{"show", value}
		cases["ack-id-"+name] = []string{"ack", value + ":" + coordinatorVersion, "--retry-key", "key", "--disposition", "reviewed"}
	}
	for name, value := range map[string]string{"empty": "", "short": strings.Repeat("a", 63), "long": strings.Repeat("a", 65), "uppercase": strings.ToUpper(coordinatorVersion), "nonhex": strings.Repeat("g", 64), "prefix": "sha256:" + coordinatorVersion, "newline": coordinatorVersion + "\n"} {
		cases["version-"+name] = []string{"ack", coordinatorDecisionA + ":" + value, "--retry-key", "key", "--disposition", "reviewed"}
	}
	for _, value := range []string{"", "Reviewed", "answered", "reviewed\n", "reviewed,deferred"} {
		cases["disposition-"+value] = []string{"ack", item, "--retry-key", "key", "--disposition", value}
	}
	for name, value := range map[string]string{"empty": "", "uppercase": "Task", "dot": "task.1", "path": "task/1", "prefix": "_task", "newline": "task\n", "overlong": strings.Repeat("a", 129), "unicode": "task-α"} {
		cases["task-"+name] = []string{"heartbeat", "--status", "busy", "--task", value}
	}
	for _, tc := range coordinatorCommandCases() {
		for _, flag := range []string{"--captain", "--body=x", "--channel=x", "--recipient=x", "--protocol-revision=1", "--availability=x", "--profile=x", "--backend=x"} {
			cases[tc.name+"-unknown-"+flag] = append(append([]string(nil), tc.args...), flag)
		}
	}
	overlong := []string{"ack"}
	for i := 0; i < 21; i++ {
		overlong = append(overlong, fmt.Sprintf("%08x-aaaa-4aaa-8aaa-aaaaaaaaaaaa:%s", i, coordinatorVersion))
	}
	cases["too-many-items"] = append(overlong, "--retry-key", "key", "--disposition", "reviewed")
	calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid request reached API") })
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			out, _, err := coordinatorCommand(args...)
			if err == nil || out != "" || calls.Load() != 0 {
				t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
			}
		})
	}
}

func TestCoordinatorInputBoundaries(t *testing.T) {
	cases := map[string][]string{
		"minimum-page":   {"tick", "--limit", "1", "--max-bytes", "4096"},
		"maximum-cursor": {"tick", "--cursor", strings.Repeat("🙂", 1024)},
		"maximum-task":   {"heartbeat", "--status", "busy", "--task", strings.Repeat("a", 128)},
		"single-task":    {"heartbeat", "--status", "busy", "--task", "0"},
	}
	for _, key := range []string{strings.Repeat("k", 128), strings.Repeat("🙂", 32)} {
		args := []string{"ack"}
		for i := 19; i >= 0; i-- {
			args = append(args, fmt.Sprintf("%08x-aaaa-4aaa-8aaa-aaaaaaaaaaaa:%s", i, coordinatorVersion))
		}
		cases["maximum-batch-"+key] = append(args, "--retry-key", key, "--disposition", "deferred")
	}
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/api/v1/coordinator/ack" {
					var payload struct {
						Items []struct{ ID string } `json:"items"`
					}
					if json.NewDecoder(r.Body).Decode(&payload) != nil || len(payload.Items) != 20 {
						t.Fatal("invalid maximum batch")
					}
					for i := 1; i < len(payload.Items); i++ {
						if payload.Items[i-1].ID >= payload.Items[i].ID {
							t.Error("batch was not normalized")
						}
					}
				}
				fmt.Fprint(w, `{"protocol_revision":1}`)
			})
			if _, _, err := coordinatorCommand(args...); err != nil || calls.Load() != 2 {
				t.Fatalf("requests %d error %v", calls.Load(), err)
			}
		})
	}
}

func TestCoordinatorRequiresCompatibleMetadata(t *testing.T) {
	metadata := map[string]string{
		"old-schema":       `{"api_version":1,"schema_version":39,"coordinator_protocol_revision":1}`,
		"wrong-api":        `{"api_version":2,"schema_version":40,"coordinator_protocol_revision":1}`,
		"missing-protocol": `{"api_version":1,"schema_version":40}`,
		"missing-schema":   `{"api_version":1,"coordinator_protocol_revision":1}`,
	}
	for name, value := range map[string]string{"old": "0", "future": "2", "null": "null", "string": `"1"`, "float": "1.0", "bool": "true", "object": "{}", "array": "[]"} {
		metadata["protocol-"+name] = `{"api_version":1,"schema_version":40,"coordinator_protocol_revision":` + value + `}`
	}
	for _, tc := range coordinatorCommandCases() {
		for name, meta := range metadata {
			t.Run(tc.name+"/"+name, func(t *testing.T) {
				calls := coordinatorServer(t, meta, func(w http.ResponseWriter, r *http.Request) { t.Error("incompatible server received runner operation") })
				out, _, err := coordinatorCommand(tc.args...)
				var apiErr *client.Error
				if !errors.As(err, &apiErr) || apiErr.Code != "schema_unavailable" || out != "" || calls.Load() != 1 {
					t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
				}
			})
		}
	}
}

func TestCoordinatorRequiresBearerAndActorWithoutCaptainFallback(t *testing.T) {
	for _, tc := range coordinatorCommandCases() {
		for key, value := range map[string]string{"AGENTBOARD_TOKEN": "", "AGENT_ID": "invalid/actor", "AGENTBOARD_MODEL": "", "AGENTBOARD_HARNESS": " "} {
			t.Run(tc.name+"/"+key, func(t *testing.T) {
				calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid auth reached HTTP") })
				path := filepath.Join(t.TempDir(), "captain")
				if err := os.WriteFile(path, []byte("synthetic-captain-token-never-use-0123456"), 0600); err != nil {
					t.Fatal(err)
				}
				t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", path)
				t.Setenv(key, value)
				out, _, err := coordinatorCommand(tc.args...)
				if err == nil || out != "" || calls.Load() != 0 {
					t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
				}
			})
		}
	}
}

func TestCoordinatorReadsProtectedOrdinaryBearer(t *testing.T) {
	calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"protocol_revision":1,"items":[],"next_cursor":null,"complete":true}`)
	})
	path := filepath.Join(t.TempDir(), "bearer")
	if err := os.WriteFile(path, []byte(coordinatorBearer+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENTBOARD_TOKEN_FILE", path)
	out, stderr, err := coordinatorCommand("tick", "--json")
	if err != nil || calls.Load() != 2 || strings.Contains(out+stderr, coordinatorBearer) {
		t.Fatalf("requests %d output %q stderr %q error %v", calls.Load(), out, stderr, err)
	}
}

func TestCoordinatorNoLegacyFallbackOnDenial(t *testing.T) {
	for _, status := range []int{401, 403, 404, 409, 422, 503} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/v1/coordinator/ack" {
					t.Error("unexpected fallback route")
				}
				w.WriteHeader(status)
				fmt.Fprint(w, `{"error":{"code":"denied","message":"coordinator request rejected"}}`)
			})
			out, _, err := coordinatorCommand("ack", coordinatorDecisionA+":"+coordinatorVersion, "--retry-key", "key", "--disposition", "reviewed")
			if err == nil || out != "" || calls.Load() != 2 {
				t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
			}
		})
	}
}

func TestCoordinatorMixedItemsParityAndDryRun(t *testing.T) {
	input := `[{"disposition":"deferred","version":"` + coordinatorVersion + `","id":"` + coordinatorDecisionB + `"},{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `","disposition":"reviewed"}]`
	want := `{"retry_key":"mixed-key","items":[{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `","disposition":"reviewed"},{"id":"` + coordinatorDecisionB + `","version":"` + coordinatorVersion + `","disposition":"deferred"}]}`
	for _, dryRun := range []bool{false, true} {
		t.Run(fmt.Sprint(dryRun), func(t *testing.T) {
			response := `{"protocol_revision":1,"receipt":{"id":"mixed-batch"}}`
			calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) {
				body, err := io.ReadAll(r.Body)
				if err != nil || string(body) != want || r.URL.Path != "/api/v1/coordinator/ack" {
					t.Errorf("mixed batch changed: %s (%v)", body, err)
				}
				fmt.Fprint(w, response)
			})
			args := []string{"ack", "--items", input, "--retry-key", "mixed-key"}
			wantCalls, wantOutput := int32(2), response+"\n"
			if dryRun {
				args = append(args, "--dry-run")
				wantCalls, wantOutput = 0, want+"\n"
				t.Setenv("AGENTBOARD_TOKEN", "")
				t.Setenv("AGENT_ID", "")
			}
			out, stderr, err := coordinatorCommand(args...)
			if err != nil || stderr != "" || out != wantOutput || calls.Load() != wantCalls {
				t.Fatalf("requests %d output %q stderr %q error %v", calls.Load(), out, stderr, err)
			}
		})
	}
}

func TestCoordinatorItemsStrictJSON(t *testing.T) {
	item := `{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `","disposition":"reviewed"}`
	cases := map[string]string{
		"empty": "", "object": item, "null": "null", "empty-array": "[]", "trailing": "[" + item + "][]",
		"number": "[1]", "string": `["item"]`, "null-item": "[null]", "array-item": "[[]]",
		"unknown-field":           "[" + strings.TrimSuffix(item, "}") + `,"body":"not allowed"}]`,
		"duplicate-field":         "[" + strings.TrimSuffix(item, "}") + `,"id":"` + coordinatorDecisionA + `"}]`,
		"escaped-duplicate-field": "[" + strings.TrimSuffix(item, "}") + `,"\u0069d":"` + coordinatorDecisionA + `"}]`,
		"wrong-case-field":        "[" + strings.Replace(item, `"id":`, `"ID":`, 1) + "]",
		"missing-field":           `[{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `"}]`,
		"null-field":              "[" + strings.Replace(item, `"reviewed"`, "null", 1) + "]",
		"number-field":            "[" + strings.Replace(item, `"reviewed"`, "1", 1) + "]",
		"bool-field":              "[" + strings.Replace(item, `"reviewed"`, "true", 1) + "]",
		"invalid-utf8":            "[" + strings.Replace(item, "reviewed", string([]byte{0xff}), 1) + "]",
		"unpaired-surrogate":      "[" + strings.Replace(item, "reviewed", `\ud800`, 1) + "]",
		"unknown-disposition":     "[" + strings.Replace(item, "reviewed", "answered", 1) + "]",
		"uppercase-id":            "[" + strings.Replace(item, coordinatorDecisionA, strings.ToUpper(coordinatorDecisionA), 1) + "]",
		"uppercase-version":       "[" + strings.Replace(item, coordinatorVersion, strings.ToUpper(coordinatorVersion), 1) + "]",
		"duplicate-source":        "[" + item + "," + item + "]",
		"duplicate-source-mixed":  "[" + item + "," + strings.Replace(item, "reviewed", "deferred", 1) + "]",
		"over-bytes":              strings.Repeat(" ", 16384) + "[" + item + "]",
		"over-count":              "[" + strings.Repeat(item+",", 20) + item + "]",
	}
	calls := coordinatorServer(t, coordinatorMeta, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid JSON reached API") })
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			out, _, err := coordinatorCommand("ack", "--items", input, "--retry-key", "key", "--dry-run")
			if err == nil || out != "" || calls.Load() != 0 {
				t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
			}
		})
	}
	for _, extra := range [][]string{{coordinatorDecisionA + ":" + coordinatorVersion}, {"--disposition", "reviewed"}, {"--disposition", ""}} {
		args := append([]string{"ack", "--items", "[" + item + "]", "--retry-key", "key", "--dry-run"}, extra...)
		if out, _, err := coordinatorCommand(args...); err == nil || out != "" || calls.Load() != 0 {
			t.Fatalf("mixed input accepted: %v output %q error %v", extra, out, err)
		}
	}
}

func TestCoordinatorItemsExactByteBoundary(t *testing.T) {
	item := `{"id":"` + coordinatorDecisionA + `","version":"` + coordinatorVersion + `","disposition":"reviewed"}`
	input := "[" + item + "]"
	input = strings.Repeat(" ", 16384-len(input)) + input
	if out, _, err := coordinatorCommand("ack", "--items", input, "--retry-key", "key", "--dry-run"); err != nil || out == "" {
		t.Fatalf("exact byte boundary failed: %q error %v", out, err)
	}
}
