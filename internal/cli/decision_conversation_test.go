package cli_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
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
	conversationDecisionID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	conversationInboxID    = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	conversationIntentID   = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	conversationSHA256     = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	conversationBearer     = "synthetic-participant-bearer-0123456789"
)

type conversationCommandCase struct {
	name, method, suffix string
	args                 []string
	payload              map[string]any
}

func conversationCommandCases() []conversationCommandCase {
	return []conversationCommandCase{
		{"notify", http.MethodPost, "", []string{"notify", conversationDecisionID, "--channel", "fixture-channel_1"}, map[string]any{"channel_id": "fixture-channel_1"}},
		{"show", http.MethodGet, "", []string{"show", conversationDecisionID}, nil},
		{"reply", http.MethodPost, "/replies", []string{"reply", conversationDecisionID, "--inbox-id", conversationInboxID, "--version", conversationSHA256, "--retry-key", "fixture-reply-1", "--body", " Keep exact text: α <>&\n🙂 "}, map[string]any{"inbox_id": conversationInboxID, "version": conversationSHA256, "retry_key": "fixture-reply-1", "body": " Keep exact text: α <>&\n🙂 "}},
		{"reconcile", http.MethodPost, "/reconcile", []string{"reconcile", conversationDecisionID, "--intent-id", conversationIntentID}, map[string]any{"intent_id": conversationIntentID}},
	}
}

func decisionConversationServer(t *testing.T, schema int, handler http.HandlerFunc) *atomic.Int32 {
	t.Helper()
	return decisionConversationCapabilityServer(t, schema, "true", handler)
}

func decisionConversationCapabilityServer(t *testing.T, schema int, capability string, handler http.HandlerFunc) *atomic.Int32 {
	t.Helper()
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer "+conversationBearer {
			t.Error("typed conversation must use the ordinary bearer")
		}
		for _, name := range []string{"X-Agentboard-Captain-Token", "X-Agentboard-Worker-Protocol"} {
			if r.Header.Get(name) != "" {
				t.Errorf("unexpected protected capability header %s", name)
			}
		}
		if r.URL.Path == "/api/v1/meta" {
			if r.Method != http.MethodGet || r.URL.RawQuery != "" {
				t.Errorf("unexpected metadata request %s %s", r.Method, r.URL)
			}
			capabilityField := ""
			if capability != "" {
				capabilityField = `,"decision_conversation_supported":` + capability
			}
			fmt.Fprintf(w, `{"api_version":1,"schema_version":%d%s}`, schema, capabilityField)
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_TOKEN", conversationBearer)
	t.Setenv("AGENTBOARD_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_CA_FILE", "")
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", filepath.Join(t.TempDir(), "must-not-be-read"))
	t.Setenv("AGENT_ID", "fixture-coordinator")
	t.Setenv("AGENTBOARD_MODEL", "fixture-model")
	t.Setenv("AGENTBOARD_HARNESS", "codex")
	return &calls
}

func decisionConversationCommand(args ...string) (string, string, error) {
	root := cli.NewRoot()
	var out, stderr bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&stderr)
	root.SetArgs(append([]string{"decision", "conversation"}, args...))
	err := root.Execute()
	return out.String(), stderr.String(), err
}

func TestDecisionConversationExactTransport(t *testing.T) {
	for _, tc := range conversationCommandCases() {
		t.Run(tc.name, func(t *testing.T) {
			response := `{"intent":{"state":"uncertain","reason":"response_lost","decision_id":"` + conversationDecisionID + `","source_inbox_id":"` + conversationInboxID + `","source_version":"` + conversationSHA256 + `","post_id":null,"handled_at":null}}`
			if tc.name == "show" {
				response = `{"intents":[],"decision_id":"` + conversationDecisionID + `"}`
			}
			calls := decisionConversationServer(t, 39, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != tc.method || r.URL.Path != "/api/v1/decisions/"+conversationDecisionID+"/conversation"+tc.suffix || r.URL.RawQuery != "" {
					t.Errorf("unexpected request %s %s", r.Method, r.URL)
				}
				for name, want := range map[string]string{"X-Agentboard-Agent": "fixture-coordinator", "X-Agentboard-Model": "fixture-model", "X-Agentboard-Harness": "codex"} {
					if r.Header.Get(name) != want {
						t.Errorf("incorrect actor attribution %s", name)
					}
				}
				body, err := io.ReadAll(r.Body)
				if err != nil {
					t.Error(err)
				}
				if tc.payload == nil {
					if len(body) != 0 {
						t.Errorf("show sent a body: %s", body)
					}
				} else {
					var got map[string]any
					if err := json.Unmarshal(body, &got); err != nil || !reflect.DeepEqual(got, tc.payload) {
						t.Errorf("payload mismatch: got %s, error %v", body, err)
					}
				}
				fmt.Fprint(w, response)
			})
			out, stderr, err := decisionConversationCommand(append(tc.args, "--json")...)
			if err != nil || stderr != "" || calls.Load() != 2 || out != response+"\n" {
				t.Fatalf("requests %d output %q stderr %q error %v", calls.Load(), out, stderr, err)
			}
		})
	}
}

func TestDecisionConversationByteBoundaries(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"single-channel", []string{"notify", conversationDecisionID, "--channel", "_"}},
		{"max-channel", []string{"notify", conversationDecisionID, "--channel", strings.Repeat("A_-1", 32)}},
		{"ascii-reply", []string{"reply", conversationDecisionID, "--inbox-id", conversationInboxID, "--version", conversationSHA256, "--retry-key", strings.Repeat("k", 128), "--body", strings.Repeat("x", 16000)}},
		{"four-byte-reply", []string{"reply", conversationDecisionID, "--inbox-id", conversationInboxID, "--version", conversationSHA256, "--retry-key", strings.Repeat("🙂", 32), "--body", strings.Repeat("🙂", 4000)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			calls := decisionConversationServer(t, 39, func(w http.ResponseWriter, r *http.Request) {
				var payload map[string]string
				if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
					t.Error(err)
				}
				if tc.args[0] == "notify" {
					if payload["channel_id"] != tc.args[3] {
						t.Error("channel was changed")
					}
				} else if payload["retry_key"] != tc.args[7] || payload["body"] != tc.args[9] {
					t.Error("bounded UTF-8 input was changed")
				}
				fmt.Fprint(w, `{"intent":{"state":"prepared"}}`)
			})
			if _, _, err := decisionConversationCommand(tc.args...); err != nil || calls.Load() != 2 {
				t.Fatalf("requests %d error %v", calls.Load(), err)
			}
		})
	}
}

func TestDecisionConversationInvalidInputBeforeHTTP(t *testing.T) {
	cases := map[string][]string{
		"notify-missing-channel":   {"notify", conversationDecisionID},
		"reply-missing-flags":      {"reply", conversationDecisionID},
		"reconcile-missing-intent": {"reconcile", conversationDecisionID},
	}
	for _, command := range conversationCommandCases() {
		for name, id := range map[string]string{
			"empty": "", "uppercase": strings.ToUpper(conversationDecisionID), "short": "abc", "compact": strings.ReplaceAll(conversationDecisionID, "-", ""), "path": conversationDecisionID + "/answer", "suffix": conversationDecisionID + " ", "prefix": " " + conversationDecisionID, "braced": "{" + conversationDecisionID + "}", "newline": conversationDecisionID + "\n", "non-hex": strings.ReplaceAll(conversationDecisionID, "a", "g"),
		} {
			args := append([]string(nil), command.args...)
			args[1] = id
			cases[command.name+"-id-"+name] = args
		}
		cases[command.name+"-missing-id"] = []string{command.name}
		cases[command.name+"-extra-id"] = append(append([]string(nil), command.args...), conversationDecisionID)
		for _, flag := range []string{"--captain", "--captain=false", "--channel-id=x", "--root-id=x", "--task=x", "--to=x"} {
			cases[command.name+"-unknown-"+flag] = append(append([]string(nil), command.args...), flag)
		}
	}
	for name, channel := range map[string]string{
		"empty": "", "space": " ", "slash": "a/b", "query": "a?b", "dot": "a.b", "unicode": "α", "too-long": strings.Repeat("a", 129), "newline": "channel\n", "nul": "a\x00b", "bad-utf8": string([]byte{0xff}),
	} {
		cases["channel-"+name] = []string{"notify", conversationDecisionID, "--channel", channel}
	}
	baseReply := conversationCommandCases()[2].args
	for name, value := range map[string]string{
		"empty": "", "uppercase": strings.ToUpper(conversationInboxID), "path": conversationInboxID + "/ack", "short": "1234", "suffix": conversationInboxID + " ",
	} {
		args := append([]string(nil), baseReply...)
		args[3] = value
		cases["inbox-"+name] = args
		cases["intent-"+name] = []string{"reconcile", conversationDecisionID, "--intent-id", value}
	}
	for name, value := range map[string]string{
		"empty": "", "short": strings.Repeat("a", 63), "long": strings.Repeat("a", 65), "uppercase": strings.ToUpper(conversationSHA256), "non-hex": strings.Repeat("g", 64), "suffix": conversationSHA256 + "\n", "sha-prefix": "sha256:" + conversationSHA256,
	} {
		args := append([]string(nil), baseReply...)
		args[5] = value
		cases["version-"+name] = args
	}
	for _, field := range []struct {
		name         string
		index, limit int
	}{{"retry-key", 7, 128}, {"body", 9, 16000}} {
		for name, value := range map[string]string{
			"empty": "", "blank": " \t\n", "unicode-blank": "\u2003", "nul": "text\x00more", "bad-utf8": string([]byte{0xff}), "ascii-over": strings.Repeat("x", field.limit+1), "four-byte-over": strings.Repeat("🙂", field.limit/4) + "x",
		} {
			args := append([]string(nil), baseReply...)
			args[field.index] = value
			cases[field.name+"-"+name] = args
		}
	}
	calls := decisionConversationServer(t, 39, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid input reached the API") })
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			out, _, err := decisionConversationCommand(args...)
			if err == nil || out != "" || calls.Load() != 0 {
				t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
			}
		})
	}
}

func TestDecisionConversationRequiresActorBeforeHTTP(t *testing.T) {
	for _, tc := range conversationCommandCases() {
		for name, value := range map[string]string{"AGENT_ID": "invalid/actor", "AGENTBOARD_MODEL": "", "AGENTBOARD_HARNESS": " "} {
			t.Run(tc.name+"/"+name, func(t *testing.T) {
				calls := decisionConversationServer(t, 39, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid actor reached the API") })
				t.Setenv(name, value)
				out, _, err := decisionConversationCommand(tc.args...)
				if err == nil || out != "" || calls.Load() != 0 {
					t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
				}
			})
		}
	}
}

func TestDecisionConversationRequiresSchema39(t *testing.T) {
	for _, tc := range conversationCommandCases() {
		for _, schema := range []int{38, 39} {
			t.Run(fmt.Sprintf("%s/schema-%d", tc.name, schema), func(t *testing.T) {
				calls := decisionConversationServer(t, schema, func(w http.ResponseWriter, r *http.Request) {
					if schema < 39 {
						t.Error("incompatible server received a feature request")
					}
					fmt.Fprint(w, `{"intent":{"state":"blocked"}}`)
				})
				out, _, err := decisionConversationCommand(append(tc.args, "--json")...)
				if schema < 39 {
					var apiErr *client.Error
					if !errors.As(err, &apiErr) || apiErr.Code != "schema_unavailable" || out != "" || calls.Load() != 1 {
						t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
					}
				} else if err != nil || out == "" || calls.Load() != 2 {
					t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
				}
			})
		}
	}
}

func TestDecisionConversationRequiresAdvertisedCapability(t *testing.T) {
	for _, tc := range conversationCommandCases() {
		for name, capability := range map[string]string{
			"false": "false", "missing": "", "null": "null", "string": `"true"`, "number": "1", "object": "{}", "array": "[]",
		} {
			t.Run(tc.name+"/"+name, func(t *testing.T) {
				calls := decisionConversationCapabilityServer(t, 39, capability, func(w http.ResponseWriter, r *http.Request) {
					t.Error("unadvertised capability received a feature request")
				})
				out, _, err := decisionConversationCommand(append(tc.args, "--json")...)
				var apiErr *client.Error
				if !errors.As(err, &apiErr) || apiErr.Code != "schema_unavailable" || out != "" || calls.Load() != 1 {
					t.Fatalf("requests %d output %q error %v", calls.Load(), out, err)
				}
			})
		}
	}
}

func TestDecisionConversationCapabilityLeavesLegacyDecisionsUnchanged(t *testing.T) {
	for name, capability := range map[string]string{"false": "false", "missing": "", "malformed-type": `"true"`} {
		t.Run(name, func(t *testing.T) {
			calls := decisionConversationCapabilityServer(t, 20, capability, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.URL.Path != "/api/v1/decisions/"+conversationDecisionID {
					t.Errorf("legacy decision request changed: %s %s", r.Method, r.URL)
				}
				fmt.Fprint(w, `{"decision":{"id":"`+conversationDecisionID+`"}}`)
			})
			root := cli.NewRoot()
			var out bytes.Buffer
			root.SetOut(&out)
			root.SetErr(io.Discard)
			root.SetArgs([]string{"decision", "show", conversationDecisionID, "--json"})
			if err := root.Execute(); err != nil || calls.Load() != 2 || out.Len() == 0 {
				t.Fatalf("legacy capability check changed: requests %d output %q error %v", calls.Load(), out.String(), err)
			}
		})
	}
}

func TestDecisionConversationPreservesReceipts(t *testing.T) {
	for _, tc := range conversationCommandCases() {
		for _, state := range []string{"prepared", "submitting", "sent", "uncertain", "blocked"} {
			for _, jsonMode := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/json-%v", tc.name, state, jsonMode), func(t *testing.T) {
					intent := `{"id":"` + conversationIntentID + `","decision_id":"` + conversationDecisionID + `","state":"` + state + `","reason":"fixture-disposition","board_notice_id":42,"source":{"inbox_id":"` + conversationInboxID + `","version":"` + conversationSHA256 + `"},"post_id":null,"received_at":null,"handled_at":null}`
					response := `{"intent":` + intent + `}`
					if tc.name == "show" {
						response = `{"intents":[` + intent + `]}`
					}
					calls := decisionConversationServer(t, 39, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, response) })
					args := append([]string(nil), tc.args...)
					if jsonMode {
						args = append(args, "--json")
					}
					out, _, err := decisionConversationCommand(args...)
					if err != nil || calls.Load() != 2 || out != response+"\n" {
						t.Fatalf("receipt changed: requests %d output %q error %v", calls.Load(), out, err)
					}
				})
			}
		}
	}
}

func TestDecisionConversationIgnoresCaptainSecret(t *testing.T) {
	const captainSecret = "synthetic-captain-capability-must-not-be-used"
	for _, tc := range conversationCommandCases() {
		t.Run(tc.name, func(t *testing.T) {
			calls := decisionConversationServer(t, 39, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, `{"intent":{"state":"uncertain"}}`) })
			path := filepath.Join(t.TempDir(), "captain-secret")
			if err := os.WriteFile(path, []byte(captainSecret), 0600); err != nil {
				t.Fatal(err)
			}
			t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", path)
			out, stderr, err := decisionConversationCommand(append(tc.args, "--json")...)
			if err != nil || calls.Load() != 2 || strings.Contains(out+stderr, captainSecret) || strings.Contains(out+stderr, conversationBearer) {
				t.Fatalf("requests %d output %q stderr %q error %v", calls.Load(), out, stderr, err)
			}
		})
	}
}

func TestDecisionConversationLeavesLegacyDecisionSchemaUnchanged(t *testing.T) {
	for _, command := range []string{"show", "list", "ack"} {
		t.Run(command, func(t *testing.T) {
			calls := decisionConversationServer(t, 20, func(w http.ResponseWriter, r *http.Request) {
				if strings.Contains(r.URL.Path, "/conversation") {
					t.Error("legacy decision acquired a conversation path")
				}
				fmt.Fprint(w, `{"decision":{"id":"`+conversationDecisionID+`"}}`)
			})
			args := []string{"decision", command, "--json"}
			if command != "list" {
				args = append(args, strings.ToUpper(conversationDecisionID))
			}
			if command != "ack" {
				t.Setenv("AGENT_ID", "")
				t.Setenv("AGENTBOARD_MODEL", "")
				t.Setenv("AGENTBOARD_HARNESS", "")
			}
			root := cli.NewRoot()
			var out bytes.Buffer
			root.SetOut(&out)
			root.SetErr(io.Discard)
			root.SetArgs(args)
			if err := root.Execute(); err != nil || calls.Load() != 2 || out.Len() == 0 {
				t.Fatalf("legacy command changed: requests %d output %q error %v", calls.Load(), out.String(), err)
			}
		})
	}
}

func TestDecisionConversationHelpPreservesAuthorityBoundary(t *testing.T) {
	calls := decisionConversationServer(t, 39, func(w http.ResponseWriter, r *http.Request) { t.Error("help reached the API") })
	for _, command := range []string{"", "notify", "show", "reply", "reconcile"} {
		args := []string{"--help"}
		if command != "" {
			args = append([]string{command}, args...)
		}
		out, _, err := decisionConversationCommand(args...)
		if err != nil || calls.Load() != 0 || !strings.Contains(out, "canonical board decision remains authoritative") || !strings.Contains(out, "protected worker mattermost-ack") {
			t.Fatalf("authority boundary missing for %q: %q error %v", command, out, err)
		}
	}
}
