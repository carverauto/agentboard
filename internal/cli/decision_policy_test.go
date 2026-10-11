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
	policyDecision = "11111111-1111-4111-8111-111111111111"
	policyVersion  = "22222222-2222-4222-8222-222222222222"
	policyHash     = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	policyMeta     = `{"api_version":1,"schema_version":41,"decision_policy_protocol_revision":1}`
	policyBearer   = "synthetic-policy-reader-0123456789abcdef"
	policyCaptain  = "synthetic-policy-captain-0123456789abcdef"
	policyDocument = `{"apiVersion":"agentboard/v1alpha1","kind":"CaptainDecisionPolicy","metadata":{"name":"fixture","version":1,"status":"draft"},"rules":[]}`
	policyResponse = `{"evaluations":[],"next_cursor":"opaque-next","mode":"dry_run","state":{"generation":2},"escalation_delivery":"unavailable"}`
)

func policyFile(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func policyCommand(args ...string) (string, error) {
	root := cli.NewRoot()
	var output bytes.Buffer
	root.SetOut(&output)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(append([]string{"decision", "policy"}, args...))
	err := root.Execute()
	return output.String(), err
}

func policyServer(t *testing.T, metadata string, captain bool, handler http.HandlerFunc) *atomic.Int32 {
	t.Helper()
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		want := policyBearer
		if captain {
			want = policyCaptain
		}
		if r.Header.Get("Authorization") != "Bearer "+want {
			t.Error("wrong policy capability transport")
		}
		for _, header := range []string{"X-Agentboard-Captain-Token", "X-Agentboard-Worker-Protocol", "X-Agentboard-Coordinator-Protocol"} {
			if r.Header.Get(header) != "" {
				t.Errorf("unexpected capability header %s", header)
			}
		}
		if r.URL.Path == "/api/v1/meta" {
			if r.Method != http.MethodGet || r.URL.RawQuery != "" {
				t.Error("metadata bootstrap must be a plain GET")
			}
			fmt.Fprint(w, metadata)
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_TOKEN", policyBearer)
	t.Setenv("AGENTBOARD_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_CA_FILE", "")
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	t.Setenv("AGENT_ID", "")
	t.Setenv("AGENTBOARD_MODEL", "")
	t.Setenv("AGENTBOARD_HARNESS", "")
	t.Setenv("AGENTBOARD_CLAIM_TTL", "")
	t.Setenv("AGENTBOARD_STALE_AFTER", "")
	if captain {
		t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", policyFile(t, policyCaptain+"\n"))
		// Protected captain operations are independent of ordinary credentials.
		t.Setenv("AGENTBOARD_TOKEN", "")
		t.Setenv("AGENTBOARD_TOKEN_FILE", "/nonexistent/ordinary-policy-token")
	} else {
		t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", "/nonexistent/captain-policy-token")
	}
	return &calls
}

func assertPolicyBody(t *testing.T, r *http.Request, want string) {
	t.Helper()
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		t.Fatal(err)
	}
	if want == "" {
		if len(raw) != 0 {
			t.Errorf("unexpected body %s", raw)
		}
		return
	}
	var gotValue, wantValue any
	gotDecoder, wantDecoder := json.NewDecoder(bytes.NewReader(raw)), json.NewDecoder(strings.NewReader(want))
	gotDecoder.UseNumber()
	wantDecoder.UseNumber()
	if gotDecoder.Decode(&gotValue) != nil || wantDecoder.Decode(&wantValue) != nil || !reflect.DeepEqual(gotValue, wantValue) {
		t.Errorf("body %s, want %s", raw, want)
	}
}

func TestDecisionPolicyReadOnlyTransportAndDefaultPlan(t *testing.T) {
	for _, jsonMode := range []bool{false, true} {
		for _, name := range []string{"default", "default-file", "plan", "plan-file", "validate", "explain", "explain-file", "list", "show", "ledger"} {
			t.Run(fmt.Sprintf("%s/json-%v", name, jsonMode), func(t *testing.T) {
				file := policyFile(t, policyDocument)
				var args []string
				method, path, body := http.MethodPost, "decisions/policy/plan", `{"limit":20,"include_closed":false}`
				query := url.Values{}
				switch name {
				case "plan":
					args = []string{"plan"}
				case "default-file":
					args = []string{"--file", file}
					body = `{"limit":20,"include_closed":false,"policy":` + policyDocument + `}`
				case "plan-file":
					args = []string{"plan", "--file", file, "--limit", "100", "--include-closed", "--cursor", "opaque+/=?&cursor"}
					body = `{"limit":100,"include_closed":true,"cursor":"opaque+/=?&cursor","policy":` + policyDocument + `}`
				case "validate":
					args, path, body = []string{"validate", "--file", file}, "decisions/policy/validate", `{"policy":`+policyDocument+`}`
				case "explain", "explain-file":
					args, path, body = []string{"explain", policyDecision}, "decisions/policy/explain/"+policyDecision, `{}`
					if name == "explain-file" {
						args = append(args, "--file", file)
						body = `{"policy":` + policyDocument + `}`
					}
				case "list":
					args, method, path, body = []string{"list"}, http.MethodGet, "decisions/policy", ""
				case "show":
					args, method, path, body = []string{"show", policyVersion}, http.MethodGet, "decisions/policy/versions/"+policyVersion, ""
				case "ledger":
					args, method, path, body = []string{"ledger", "--decision-id", policyDecision, "--policy-id", policyVersion, "--cursor", "cursor+/=?&", "--limit", "99"}, http.MethodGet, "decisions/policy/ledger", ""
					query = url.Values{"decision_id": {policyDecision}, "policy_id": {policyVersion}, "cursor": {"cursor+/=?&"}, "limit": {"99"}}
				}
				calls := policyServer(t, policyMeta, false, func(w http.ResponseWriter, r *http.Request) {
					if r.Method != method || r.URL.Path != "/api/v1/"+path || r.URL.RawQuery != query.Encode() {
						t.Errorf("unexpected operation %s %s", r.Method, r.URL)
					}
					assertPolicyBody(t, r, body)
					fmt.Fprint(w, policyResponse)
				})
				if jsonMode {
					args = append(args, "--json")
				}
				output, err := policyCommand(args...)
				if err != nil || calls.Load() != 2 || output != policyResponse+"\n" || strings.Contains(output, policyBearer) {
					t.Fatalf("calls %d output %q error %v", calls.Load(), output, err)
				}
			})
		}
	}
}

func policyApplyArgs() []string {
	return []string{"apply", policyDecision, "--policy-id", policyVersion, "--generation", "2", "--source-version", policyHash, "--day", "2026-10-11", "--answer-sha256", policyHash}
}

func TestDecisionPolicyExplicitCaptainOperations(t *testing.T) {
	for _, action := range []string{"draft", "approve", "activate", "deactivate", "apply"} {
		t.Run(action, func(t *testing.T) {
			var args []string
			var path, body string
			switch action {
			case "draft":
				args = []string{"draft", "--file", policyFile(t, policyDocument)}
				path, body = "decisions/policy/drafts", `{"policy":`+policyDocument+`}`
			case "approve":
				args = []string{"approve", policyVersion, "--sha256", policyHash}
				path, body = "decisions/policy/versions/"+policyVersion+"/approve", `{"sha256":"`+policyHash+`"}`
			case "activate":
				args = []string{"activate", policyVersion, "--sha256", policyHash, "--generation", "0"}
				path, body = "decisions/policy/versions/"+policyVersion+"/activate", `{"sha256":"`+policyHash+`","generation":0}`
			case "deactivate":
				args = []string{"deactivate", "--generation", "2"}
				path, body = "decisions/policy/deactivate", `{"generation":2}`
			case "apply":
				args = policyApplyArgs()
				path, body = "decisions/policy/apply/"+policyDecision, `{"policy_id":"`+policyVersion+`","generation":2,"source_version":"`+policyHash+`","day":"2026-10-11","answer_sha256":"`+policyHash+`"}`
			}
			calls := policyServer(t, policyMeta, true, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodPost || r.URL.Path != "/api/v1/"+path || r.URL.RawQuery != "" {
					t.Errorf("unexpected operation %s %s", r.Method, r.URL)
				}
				assertPolicyBody(t, r, body)
				fmt.Fprint(w, `{"replayed":true,"state":{"generation":3},"mode":"dry_run"}`)
			})
			output, err := policyCommand(args...)
			if err != nil || calls.Load() != 2 || !strings.Contains(output, `"replayed":true`) || strings.Contains(output, policyCaptain) {
				t.Fatalf("calls %d output %q error %v", calls.Load(), output, err)
			}
		})
	}
}

func TestDecisionPolicyRejectsInvalidInputBeforeHTTP(t *testing.T) {
	cases := [][]string{
		{"validate"}, {"draft"}, {"plan", "--file", ""}, {"explain", policyDecision, "--file", ""},
		{"plan", "--limit", "0"}, {"plan", "--limit", "101"}, {"plan", "--cursor", ""}, {"plan", "--cursor", strings.Repeat("a", 4097)},
		{"ledger", "--limit", "-1"}, {"ledger", "--cursor", "\x00"}, {"ledger", "--decision-id", ""}, {"ledger", "--policy-id", "not-uuid"},
		{"show", strings.ToUpper("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")}, {"show", "../bad"}, {"show"}, {"list", "extra"}, {"unknown"},
		{"approve", policyVersion}, {"approve", policyVersion, "--sha256", strings.ToUpper(policyHash)},
		{"activate", policyVersion, "--sha256", policyHash}, {"activate", policyVersion, "--sha256", policyHash, "--generation", "-1"},
		{"deactivate"}, {"deactivate", "--generation", "1.5"}, {"deactivate", "--generation", "9223372036854775808"},
		{"deactivate", "--generation", "0", "--captain=false"},
		{"apply", policyDecision}, {"apply", policyDecision, "--file", "not-supported"}, {"plan", "--verified", policyDecision},
	}
	for _, pair := range [][2]string{{"--policy-id", "bad"}, {"--generation", "-1"}, {"--source-version", "bad"}, {"--answer-sha256", "bad"}, {"--day", "2026-02-30"}, {"--day", "2026-1-01"}, {"--day", "2026-10-11T00:00:00Z"}} {
		args := policyApplyArgs()
		for i := range args {
			if args[i] == pair[0] {
				args[i+1] = pair[1]
			}
		}
		cases = append(cases, args)
	}
	for index, args := range cases {
		t.Run(fmt.Sprint(index), func(t *testing.T) {
			calls := policyServer(t, policyMeta, false, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid request reached feature route") })
			output, err := policyCommand(args...)
			if err == nil || calls.Load() != 0 || output != "" || cli.ExitCode(err) != 2 {
				t.Fatalf("invalid %q: calls %d output %q error %v", args, calls.Load(), output, err)
			}
		})
	}
}

func TestDecisionPolicyStrictJSONFiles(t *testing.T) {
	cases := map[string]string{
		"empty": "", "yaml": "kind: CaptainDecisionPolicy", "array": "[]", "null": "null", "number": "1", "trailing": "{} {}",
		"duplicate-top": `{"kind":"a","kind":"b"}`, "duplicate-nested": `{"rules":[{"match":{"a":1,"a":2}}]}`,
		"duplicate-escaped": `{"kind":"a","\u006bind":"b"}`, "invalid-utf8": "{\"key\":\"" + string([]byte{0xff}) + "\"}",
		"surrogate": `{"key":"\ud800"}`, "excessive": strings.Repeat(" ", 256*1024) + `{}`,
		"depth": `{"a":` + strings.Repeat("[", 65) + "0" + strings.Repeat("]", 65) + `}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			calls := policyServer(t, policyMeta, false, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid file reached API") })
			output, err := policyCommand("validate", "--file", policyFile(t, body))
			if err == nil || calls.Load() != 0 || output != "" {
				t.Fatalf("invalid file accepted: calls %d output %q error %v", calls.Load(), output, err)
			}
		})
	}
	for _, kind := range []string{"missing", "directory", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "missing")
			if kind == "directory" {
				path = t.TempDir()
			} else if kind == "symlink" {
				if err := os.Symlink(policyFile(t, `{}`), path); err != nil {
					t.Fatal(err)
				}
			}
			calls := policyServer(t, policyMeta, false, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid path reached API") })
			if output, err := policyCommand("validate", "--file", path); err == nil || output != "" || calls.Load() != 0 {
				t.Fatalf("invalid path accepted: output %q error %v", output, err)
			}
		})
	}
}

func TestDecisionPolicyLeavesSemanticValidationToServer(t *testing.T) {
	// No second schema/evaluator lives in Go, including unknown keys. The
	// authoritative server's rejection is returned without another request.
	file := policyFile(t, `{"unknown":{"large":9007199254740993},"unicode":"\ud83d\ude80"}`)
	calls := policyServer(t, policyMeta, false, func(w http.ResponseWriter, r *http.Request) {
		assertPolicyBody(t, r, `{"policy":{"unknown":{"large":9007199254740993},"unicode":"\ud83d\ude80"}}`)
		w.WriteHeader(http.StatusUnprocessableEntity)
		fmt.Fprint(w, `{"error":{"code":"invalid_input","message":"Unknown policy fields"}}`)
	})
	output, err := policyCommand("validate", "--file", file)
	if err == nil || cli.ExitCode(err) != 2 || output != "" || calls.Load() != 2 {
		t.Fatalf("calls %d output %q error %v", calls.Load(), output, err)
	}
}

func TestDecisionPolicyAcceptsExactFileSizeBoundary(t *testing.T) {
	body := `{"fixture":"` + strings.Repeat("x", 256*1024-len(`{"fixture":""}`)) + `"}`
	if len(body) != 256*1024 {
		t.Fatal("incorrect fixture size")
	}
	calls := policyServer(t, policyMeta, false, func(w http.ResponseWriter, r *http.Request) {
		assertPolicyBody(t, r, `{"policy":`+body+`}`)
		fmt.Fprint(w, `{"valid":true}`)
	})
	if output, err := policyCommand("validate", "--file", policyFile(t, body)); err != nil || output != "{\"valid\":true}\n" || calls.Load() != 2 {
		t.Fatalf("boundary file rejected: output %q error %v", output, err)
	}
}

func TestDecisionPolicyRequiresAdvertisedCompatibleContract(t *testing.T) {
	for _, meta := range []string{
		`{"api_version":1,"schema_version":40,"decision_policy_protocol_revision":1}`,
		`{"api_version":1,"schema_version":41}`,
		`{"api_version":1,"schema_version":41,"decision_policy_protocol_revision":2}`,
		`{"api_version":2,"schema_version":41,"decision_policy_protocol_revision":1}`,
		`{"api_version":1,"schema_version":41,"decision_policy_protocol_revision":"1"}`,
	} {
		t.Run(meta, func(t *testing.T) {
			calls := policyServer(t, meta, false, func(w http.ResponseWriter, r *http.Request) { t.Error("incompatible server received feature request") })
			output, err := policyCommand()
			var apiError *client.Error
			if !errors.As(err, &apiError) || apiError.Code != "schema_unavailable" || calls.Load() != 1 || output != "" {
				t.Fatalf("calls %d output %q error %v", calls.Load(), output, err)
			}
		})
	}
}

func TestDecisionPolicyApplyConflictDoesNotRefreshOrRetry(t *testing.T) {
	calls := policyServer(t, policyMeta, true, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/decisions/policy/apply/"+policyDecision {
			t.Error("apply attempted an implicit read-plan or another operation")
		}
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error":{"code":"conflict","message":"Source changed; reload"}}`)
	})
	output, err := policyCommand(policyApplyArgs()...)
	if err == nil || cli.ExitCode(err) != 4 || calls.Load() != 2 || output != "" {
		t.Fatalf("calls %d output %q error %v", calls.Load(), output, err)
	}
}

func TestDecisionPolicyMutationCompatibilityAndDenialDoNotFallback(t *testing.T) {
	for _, scenario := range []string{"old-schema", "missing-protocol", "forbidden", "server-error"} {
		t.Run(scenario, func(t *testing.T) {
			meta, wantCalls, status := policyMeta, int32(2), http.StatusForbidden
			if scenario == "old-schema" {
				meta, wantCalls = `{"api_version":1,"schema_version":40,"decision_policy_protocol_revision":1}`, 1
			} else if scenario == "missing-protocol" {
				meta, wantCalls = `{"api_version":1,"schema_version":41}`, 1
			} else if scenario == "server-error" {
				status = http.StatusServiceUnavailable
			}
			calls := policyServer(t, meta, true, func(w http.ResponseWriter, r *http.Request) {
				if wantCalls == 1 || r.URL.Path != "/api/v1/decisions/policy/deactivate" {
					t.Error("mutation tried an incompatible route or fallback")
				}
				w.WriteHeader(status)
				fmt.Fprint(w, `{"error":{"code":"forbidden","message":"Denied"}}`)
			})
			if output, err := policyCommand("deactivate", "--generation", "0"); err == nil || output != "" || calls.Load() != wantCalls {
				t.Fatalf("calls %d output %q error %v", calls.Load(), output, err)
			}
		})
	}
}

func TestDecisionPolicyCaptainFileRequiredWithoutBearerFallback(t *testing.T) {
	calls := policyServer(t, policyMeta, false, func(w http.ResponseWriter, r *http.Request) { t.Error("missing captain capability reached API") })
	output, err := policyCommand("deactivate", "--generation", "0")
	if err == nil || calls.Load() != 0 || output != "" || strings.Contains(err.Error(), policyBearer) {
		t.Fatalf("calls %d output %q error %v", calls.Load(), output, err)
	}
}

func TestDecisionPolicyCIRequestIntentIsExplicitAndBounded(t *testing.T) {
	for _, value := range []string{"absent", "0", "100", "-1", "101"} {
		t.Run(value, func(t *testing.T) {
			calls := policyServer(t, policyMeta, false, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodPost || r.URL.Path != "/api/v1/decisions" {
					t.Errorf("wrong intake route %s %s", r.Method, r.URL)
				}
				var body map[string]json.RawMessage
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				if value == "absent" {
					if _, ok := body["requested_ci_runs"]; ok {
						t.Error("omission was silently converted to zero")
					}
				} else if string(body["requested_ci_runs"]) != value {
					t.Errorf("requested_ci_runs %s, want %s", body["requested_ci_runs"], value)
				}
				fmt.Fprint(w, `{"decision":{"id":"`+policyDecision+`"}}`)
			})
			t.Setenv("AGENT_ID", "fixture-seat")
			t.Setenv("AGENTBOARD_MODEL", "fixture")
			t.Setenv("AGENTBOARD_HARNESS", "codex")
			root := cli.NewRoot()
			var output bytes.Buffer
			root.SetOut(&output)
			root.SetErr(&bytes.Buffer{})
			args := []string{"decision", "request", "fixture-task", "--question", "May I rerun CI?"}
			if value != "absent" {
				args = append(args, "--ci-runs", value)
			}
			root.SetArgs(args)
			err := root.Execute()
			invalid := value == "-1" || value == "101"
			if invalid && (err == nil || calls.Load() != 0 || output.Len() != 0) || !invalid && (err != nil || calls.Load() != 2) {
				t.Fatalf("calls %d output %q error %v", calls.Load(), output.String(), err)
			}
		})
	}
}
