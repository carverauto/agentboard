package cli_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
	"github.com/carverauto/agentboard/internal/client"
)

const triageNote = `{"version":1,"category":"status","attention":"routine","source":null}`
const triageEventID = "00000000-0000-4000-8000-000000000001"

func messageTriageServer(t *testing.T, schema int, handler http.HandlerFunc) *atomic.Int32 {
	t.Helper()
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/meta" {
			fmt.Fprintf(w, `{"api_version":1,"schema_version":%d}`, schema)
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENT_ID", "fixture-sender")
	t.Setenv("AGENTBOARD_MODEL", "fixture-model")
	t.Setenv("AGENTBOARD_HARNESS", "codex")
	return &calls
}

func messageTriageCommand(args ...string) (string, error) {
	root := cli.NewRoot()
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(append([]string{"msg"}, args...))
	err := root.Execute()
	return out.String(), err
}

func messageTriageInput(category, attention, source string) string {
	return fmt.Sprintf(`{"version":1,"category":%q,"attention":%q,"source":%s}`, category, attention, source)
}

func TestMessageTriageSendExactMetadata(t *testing.T) {
	cases := map[string]string{
		"status-null":                 triageNote,
		"status-source":               messageTriageInput("status", "routine", `{"kind":"task_status","task_id":"a_task-1","task_event_id":1,"task_revision":9007199254740991}`),
		"ci":                          messageTriageInput("ci", "routine", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":" Exact source: α<>& "}`),
		"conflict":                    messageTriageInput("conflict", "captain", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":"source"}`),
		"next-work-null":              messageTriageInput("next_work", "routine", `null`),
		"next-work-source":            messageTriageInput("next_work", "captain", `{"kind":"task_assignment","task_id":"task","assignment_revision":1}`),
		"judgment-null":               messageTriageInput("needs_judgment", "captain", `null`),
		"judgment-source":             messageTriageInput("needs_judgment", "routine", `{"kind":"decision_request","request_id":"`+triageEventID+`"}`),
		"max-task-id":                 messageTriageInput("status", "routine", `{"kind":"task_status","task_id":"`+strings.Repeat("a", 128)+`","task_event_id":1,"task_revision":1}`),
		"max-source-key":              messageTriageInput("ci", "routine", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":"`+strings.Repeat("🙂", 240)+`"}`),
		"combining-source-key":        messageTriageInput("ci", "routine", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":"`+strings.Repeat("e\u0301", 120)+`"}`),
		"space-only-source-key":       messageTriageInput("ci", "routine", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":" "}`),
		"format-source-key":           messageTriageInput("ci", "routine", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":"source\u200b"}`),
		"surrogate-pair":              messageTriageInput("ci", "routine", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":"\ud83d\ude42"}`),
		"escaped-slash":               messageTriageInput("ci", "routine", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":"\\ud800"}`),
		"unicode-replacement-literal": messageTriageInput("ci", "routine", `{"kind":"cooperation_event","event_id":"`+triageEventID+`","source_key":"�"}`),
		"boundary-bytes":              strings.Repeat(" ", 4096-len(triageNote)) + triageNote,
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			requests := 0
			messageTriageServer(t, 999, func(w http.ResponseWriter, r *http.Request) {
				requests++
				if r.Method != http.MethodPost || r.URL.Path != "/api/v1/messages" {
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
				}
				var got map[string]json.RawMessage
				if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
					t.Fatal(err)
				}
				var metadata, want any
				if err := json.Unmarshal(got["triage"], &metadata); err != nil {
					t.Fatal(err)
				}
				if err := json.Unmarshal([]byte(input), &want); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(metadata, want) || string(got["body"]) != `"Fixture note"` || string(got["to"]) != `"fixture-recipient"` || string(got["task"]) != `"fixture-task"` || len(got) != 4 {
					t.Errorf("unexpected metadata or mutation fields: %s", got)
				}
				fmt.Fprint(w, `{"message":{"id":42,"read_at":null}}`)
			})
			out, err := messageTriageCommand("send", "--to", "fixture-recipient", "--task", "fixture-task", "--body", "Fixture note", "--triage", input, "--json")
			if err != nil || requests != 1 || strings.TrimSpace(out) != `{"message":{"id":42,"read_at":null}}` {
				t.Fatalf("requests %d output %q error %v", requests, out, err)
			}
		})
	}
}

func TestMessageTriageRejectsInvalidMetadataBeforeHTTP(t *testing.T) {
	status := `{"kind":"task_status","task_id":"task","task_event_id":1,"task_revision":1}`
	event := `{"kind":"cooperation_event","event_id":"` + triageEventID + `","source_key":"source"}`
	assignment := `{"kind":"task_assignment","task_id":"task","assignment_revision":1}`
	decision := `{"kind":"decision_request","request_id":"` + triageEventID + `"}`
	cases := map[string]string{
		"empty": "", "malformed": "{", "null": "null", "array": "[]", "string": `"note"`,
		"trailing-object": triageNote + ` {}`, "trailing-garbage": triageNote + ` x`,
		"too-large":               strings.Repeat(" ", 4097-len(triageNote)) + triageNote,
		"invalid-utf8":            strings.Replace(triageNote, "status", string([]byte{0xff}), 1),
		"unknown-key":             strings.Replace(triageNote, `"version":1`, `"version":1,"provenance":"server"`, 1),
		"case-key":                strings.Replace(triageNote, `"version":1`, `"Version":1`, 1),
		"duplicate-key":           strings.Replace(triageNote, `"version":1`, `"version":1,"version":1`, 1),
		"escaped-duplicate-key":   strings.Replace(triageNote, `"version":1`, `"version":1,"vers\u0069on":1`, 1),
		"unknown-category":        messageTriageInput("unclassified", "routine", "null"),
		"wrong-category-case":     messageTriageInput("Status", "routine", "null"),
		"category-whitespace":     messageTriageInput(" status", "routine", "null"),
		"unknown-attention":       messageTriageInput("status", "human", "null"),
		"attention-whitespace":    messageTriageInput("status", "captain ", "null"),
		"ci-null":                 messageTriageInput("ci", "routine", "null"),
		"conflict-null":           messageTriageInput("conflict", "captain", "null"),
		"source-array":            messageTriageInput("status", "routine", "[]"),
		"source-string":           messageTriageInput("status", "routine", `"task_status"`),
		"wrong-source-kind":       messageTriageInput("status", "routine", event),
		"status-for-ci":           messageTriageInput("ci", "routine", status),
		"assignment-for-status":   messageTriageInput("status", "routine", assignment),
		"decision-for-next-work":  messageTriageInput("next_work", "routine", decision),
		"assignment-for-judgment": messageTriageInput("needs_judgment", "routine", assignment),
		"source-unknown-key":      messageTriageInput("status", "routine", strings.Replace(status, `"kind":`, `"trusted":true,"kind":`, 1)),
		"source-duplicate-key":    messageTriageInput("status", "routine", strings.Replace(status, `"task_id":"task"`, `"task_id":"task","task_id":"task"`, 1)),
		"source-case-key":         messageTriageInput("status", "routine", strings.Replace(status, `"task_id":`, `"Task_id":`, 1)),
	}
	for _, version := range []string{`0`, `2`, `1.0`, `1e0`, `"1"`, `null`, `true`, `{}`, `[]`} {
		cases["version-"+version] = strings.Replace(triageNote, `"version":1`, `"version":`+version, 1)
	}
	for _, key := range []string{"version", "category", "attention", "source"} {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal([]byte(triageNote), &fields); err != nil {
			t.Fatal(err)
		}
		delete(fields, key)
		encoded, _ := json.Marshal(fields)
		cases["missing-"+key] = string(encoded)
		for _, value := range []string{`null`, `0`, `true`, `[]`, `{}`} {
			if key == "source" && value == "null" {
				continue
			}
			fields[key] = json.RawMessage(value)
			encoded, _ = json.Marshal(fields)
			cases[key+"-type-"+value] = string(encoded)
		}
	}
	for _, variant := range []struct{ category, source string }{
		{"status", status}, {"ci", event}, {"next_work", assignment}, {"needs_judgment", decision},
	} {
		var source map[string]json.RawMessage
		if err := json.Unmarshal([]byte(variant.source), &source); err != nil {
			t.Fatal(err)
		}
		for key, value := range source {
			delete(source, key)
			encoded, _ := json.Marshal(source)
			cases[variant.category+"-missing-"+key] = messageTriageInput(variant.category, "routine", string(encoded))
			for _, bad := range []string{`null`, `true`, `[]`, `{}`} {
				source[key] = json.RawMessage(bad)
				encoded, _ = json.Marshal(source)
				cases[variant.category+"-"+key+"-type-"+bad] = messageTriageInput(variant.category, "routine", string(encoded))
			}
			source[key] = value
		}
	}
	for _, id := range []string{"", "Task", " task", "a/b", "-task", strings.Repeat("a", 129)} {
		encoded, _ := json.Marshal(id)
		cases["task-id-"+id] = messageTriageInput("status", "routine", strings.Replace(status, `"task"`, string(encoded), 1))
	}
	for _, bad := range []string{`0`, `-1`, `1.5`, `1.0`, `1e0`, `"1"`, `9007199254740992`, `9223372036854775808`} {
		for _, key := range []string{"task_event_id", "task_revision"} {
			cases[key+"-"+bad] = messageTriageInput("status", "routine", strings.Replace(status, `"`+key+`":1`, `"`+key+`":`+bad, 1))
		}
		cases["assignment-revision-"+bad] = messageTriageInput("next_work", "routine", strings.Replace(assignment, `"assignment_revision":1`, `"assignment_revision":`+bad, 1))
	}
	for _, bad := range []string{"", strings.Repeat("a", 36), "00000000-0000-4000-A000-000000000001", triageEventID + " "} {
		encoded, _ := json.Marshal(bad)
		cases["event-id-"+bad] = messageTriageInput("ci", "routine", strings.Replace(event, `"`+triageEventID+`"`, string(encoded), 1))
		cases["request-id-"+bad] = messageTriageInput("needs_judgment", "routine", strings.Replace(decision, `"`+triageEventID+`"`, string(encoded), 1))
	}
	for _, bad := range []string{`""`, `"` + strings.Repeat("x", 241) + `"`, `"` + strings.Repeat("🙂", 241) + `"`, `"` + strings.Repeat("e\u0301", 121) + `"`, `"source\n"`, `"source\u0000"`, `"source\u001f"`, `"source\u007f"`, `"\ud800"`, `"\udc00"`, `"\ud800\u0061"`, `"\ud800x"`} {
		cases["source-key-"+bad] = messageTriageInput("ci", "routine", strings.Replace(event, `"source"`, bad, 1))
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			calls := messageTriageServer(t, 999, func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected feature request") })
			out, err := messageTriageCommand("send", "--to", "fixture-recipient", "--body", "Private fixture note", "--triage", input)
			if err == nil || out != "" || calls.Load() != 0 {
				t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
			}
			if strings.Contains(err.Error(), "Private fixture note") {
				t.Error("body leaked in error")
			}
		})
	}
}

func TestMessageTriageRejectsTaskOrders(t *testing.T) {
	calls := messageTriageServer(t, 999, func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected feature request") })
	out, err := messageTriageCommand("send", "--to", "fixture-recipient", "--body", "Fixture order", "--kind", "task_order", "--triage", triageNote)
	if err == nil || !strings.Contains(err.Error(), "only supported") || out != "" || calls.Load() != 0 {
		t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
	}
}

func TestMessageTriageExactReadsAreNonConsuming(t *testing.T) {
	for _, command := range []string{"show", "triage"} {
		for _, jsonMode := range []bool{false, true} {
			for _, captured := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/json=%v/captured=%v", command, jsonMode, captured), func(t *testing.T) {
					response := `{"triage":null}`
					if captured {
						response = `{"triage":{"message_id":42,"classification":"status","state":"recorded","history":[],"delivery":{"state":"not_attempted"},"handling":{"read_at":null}}}`
					}
					if command == "show" {
						response = `{"message":{"id":42,"body":"Unread fixture","read_at":null,"triage":null}}`
					}
					requests := 0
					messageTriageServer(t, 999, func(w http.ResponseWriter, r *http.Request) {
						requests++
						path := "/api/v1/messages/42"
						if command == "triage" {
							path += "/triage"
						}
						if r.Method != http.MethodGet || r.URL.Path != path || r.URL.RawQuery != "" {
							t.Errorf("unexpected request %s %s", r.Method, r.URL)
						}
						fmt.Fprint(w, response)
					})
					t.Setenv("AGENT_ID", "")
					t.Setenv("AGENTBOARD_MODEL", "")
					t.Setenv("AGENTBOARD_HARNESS", "")
					args := []string{command, "42"}
					if jsonMode {
						args = append(args, "--json")
					}
					out, err := messageTriageCommand(args...)
					if err != nil || requests != 1 || out == "" {
						t.Fatalf("requests %d output %q error %v", requests, out, err)
					}
					if jsonMode && strings.TrimSpace(out) != response {
						t.Errorf("JSON response changed: %s", out)
					}
					if !jsonMode && command == "triage" && captured && !strings.Contains(out, `"state":"recorded"`) {
						t.Errorf("missing triage output: %s", out)
					}
				})
			}
		}
	}
}

func TestMessageTriageRejectsInvalidReadIDsBeforeHTTP(t *testing.T) {
	for _, command := range []string{"show", "triage"} {
		for _, id := range []string{"0", "-1", "1.5", "note", "9223372036854775808", "42/read", " 42"} {
			t.Run(command+"/"+id, func(t *testing.T) {
				calls := messageTriageServer(t, 999, func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected feature request") })
				out, err := messageTriageCommand(command, id)
				if err == nil || out != "" || calls.Load() != 0 {
					t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
				}
			})
		}
	}
}

func TestMessageTriageListFilterPreservesExistingQuery(t *testing.T) {
	for _, state := range []string{"recorded", "blocked", "escalation_pending", "unresolved"} {
		t.Run(state, func(t *testing.T) {
			requests := 0
			messageTriageServer(t, 999, func(w http.ResponseWriter, r *http.Request) {
				requests++
				want := url.Values{"triage_state": {state}, "to": {"fixture-recipient"}, "task": {"fixture-task"}, "unread": {"true"}, "limit": {"17"}, "cursor": {"fixture-cursor"}}
				if r.Method != http.MethodGet || r.URL.Path != "/api/v1/messages" || !reflect.DeepEqual(r.URL.Query(), want) {
					t.Errorf("unexpected request %s %s", r.Method, r.URL)
				}
				fmt.Fprint(w, `{"messages":[],"next_cursor":null}`)
			})
			out, err := messageTriageCommand("list", "--triage-state", state, "--to", "fixture-recipient", "--task", "fixture-task", "--unread", "--limit", "17", "--cursor", "fixture-cursor", "--json")
			if err != nil || requests != 1 || strings.TrimSpace(out) != `{"messages":[],"next_cursor":null}` {
				t.Fatalf("requests %d output %q error %v", requests, out, err)
			}
		})
	}
}

func TestMessageTriageRejectsUnsupportedFiltersBeforeHTTP(t *testing.T) {
	cases := [][]string{{"list", "--triage-state", "recorded", "--watch"}, {"watch", "--triage-state", "recorded"}}
	for _, state := range []string{"", "pending", "routed", "route_pending", "escalation_queued", "superseded", "dead_letter", "RECORDED", " recorded", "blocked,recorded"} {
		cases = append(cases, []string{"list", "--triage-state", state})
	}
	for _, args := range cases {
		t.Run(strings.Join(args, "/"), func(t *testing.T) {
			calls := messageTriageServer(t, 999, func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected feature request") })
			out, err := messageTriageCommand(args...)
			if err == nil || out != "" || calls.Load() != 0 {
				t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
			}
		})
	}
}

func TestMessageTriageLegacySendListAndReadKeepSchemaFloor(t *testing.T) {
	for _, command := range []string{"send", "list", "read"} {
		t.Run(command, func(t *testing.T) {
			requests := 0
			messageTriageServer(t, 2, func(w http.ResponseWriter, r *http.Request) {
				requests++
				if command == "send" {
					var payload map[string]json.RawMessage
					if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
						t.Fatal(err)
					}
					if _, ok := payload["triage"]; ok {
						t.Error("legacy send gained metadata")
					}
				}
				if r.URL.Query().Has("triage_state") {
					t.Error("legacy command gained filter")
				}
				fmt.Fprint(w, `{"message":{"id":42}}`)
			})
			args := []string{command, "--json"}
			switch command {
			case "send":
				args = append(args, "--body", "Legacy", "--to", "fixture-recipient")
			case "read":
				args = append(args, "42")
			}
			out, err := messageTriageCommand(args...)
			if err != nil || requests != 1 || out == "" {
				t.Fatalf("requests %d output %q error %v", requests, out, err)
			}
		})
	}
}

func TestMessageTriageRequiresSchema36(t *testing.T) {
	for _, schema := range []int{2, 15, 35, 36} {
		for _, args := range [][]string{
			{"send", "--to", "fixture-recipient", "--body", "Fixture", "--triage", triageNote},
			{"show", "42"},
			{"triage", "42"},
			{"list", "--triage-state", "recorded"},
			{"list", "--triage-state", "blocked"},
			{"list", "--triage-state", "escalation_pending"},
			{"list", "--triage-state", "unresolved"},
		} {
			t.Run(fmt.Sprintf("schema%d/%s", schema, strings.Join(args, "/")), func(t *testing.T) {
				requests := 0
				messageTriageServer(t, schema, func(w http.ResponseWriter, r *http.Request) {
					requests++
					fmt.Fprint(w, `{"message":{"id":42}}`)
				})
				out, err := messageTriageCommand(append(args, "--json")...)
				if schema < 36 {
					var apiError *client.Error
					if !errors.As(err, &apiError) || apiError.Code != "schema_unavailable" || requests != 0 || out != "" {
						t.Fatalf("feature not fenced: requests %d output %q error %v", requests, out, err)
					}
				} else if err != nil || requests != 1 || out == "" {
					t.Fatalf("schema36 feature failed: requests %d output %q error %v", requests, out, err)
				}
			})
		}
	}
}

func TestMessageTriageLegacyTaskOrdersKeepSchema15(t *testing.T) {
	for _, schema := range []int{14, 15} {
		t.Run(fmt.Sprint(schema), func(t *testing.T) {
			requests := 0
			messageTriageServer(t, schema, func(w http.ResponseWriter, r *http.Request) {
				requests++
				if r.Method != http.MethodPost || r.URL.Path != "/api/v1/messages" {
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
				}
				var payload map[string]json.RawMessage
				if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
					t.Fatal(err)
				}
				if _, ok := payload["triage"]; ok || string(payload["kind"]) != `"task_order"` {
					t.Errorf("legacy task order changed: %s", payload)
				}
				fmt.Fprint(w, `{"message":{"id":42}}`)
			})
			out, err := messageTriageCommand("send", "--to", "fixture-recipient", "--body", "Fixture order", "--kind", "task_order", "--json")
			if schema < 15 {
				var apiError *client.Error
				if !errors.As(err, &apiError) || apiError.Code != "schema_unavailable" || requests != 0 || out != "" {
					t.Fatalf("task order not fenced: requests %d output %q error %v", requests, out, err)
				}
			} else if err != nil || requests != 1 || out == "" {
				t.Fatalf("legacy task order failed: requests %d output %q error %v", requests, out, err)
			}
		})
	}
}

func TestMessageTriageLegacyWatchesKeepSchemaFloorAndQuery(t *testing.T) {
	for _, listWatch := range []bool{false, true} {
		t.Run(fmt.Sprint(listWatch), func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			requests := 0
			messageTriageServer(t, 2, func(w http.ResponseWriter, r *http.Request) {
				requests++
				want := url.Values{"to": {"fixture-recipient"}, "task": {"fixture-task"}, "unread": {"true"}}
				if r.Method != http.MethodGet || r.URL.Path != "/api/v1/messages/watch" || !reflect.DeepEqual(r.URL.Query(), want) {
					t.Errorf("unexpected watch %s %s", r.Method, r.URL)
				}
				fmt.Fprintln(w, `{"messages":[],"reason":"snapshot"}`)
				w.(http.Flusher).Flush()
				cancel()
			})
			root := cli.NewRoot()
			root.SetContext(ctx)
			root.SetOut(&bytes.Buffer{})
			root.SetErr(&bytes.Buffer{})
			args := []string{"msg", "watch"}
			if listWatch {
				args = []string{"msg", "list", "--watch", "--limit", "17", "--cursor", "ignored-for-watch"}
			}
			root.SetArgs(append(args, "--to", "fixture-recipient", "--task", "fixture-task", "--unread", "--json"))
			if err := root.Execute(); err != nil || requests != 1 {
				t.Fatalf("requests %d error %v", requests, err)
			}
		})
	}
}
