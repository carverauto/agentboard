package cli_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

type rosterBoard struct {
	beats    atomic.Int32
	retire   []byte
	register []byte
}

func newRosterBoard(t *testing.T) (string, *rosterBoard) {
	t.Helper()
	f := &rosterBoard{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"api_version":1,"schema_version":30}`))
	})
	mux.HandleFunc("POST /api/v1/agents/worker-a/retire", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		f.retire = body
		w.Write([]byte(`{"agent":{"id":"worker-a"}}`))
	})
	mux.HandleFunc("POST /api/v1/agents/worker-a/restore", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"agent":{"id":"worker-a"}}`))
	})
	mux.HandleFunc("POST /api/v1/agents/register", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		f.register = body
		w.Write([]byte(`{"agent":{"id":"worker-a"}}`))
	})
	mux.HandleFunc("POST /api/v1/agents/worker-a/heartbeat", func(w http.ResponseWriter, r *http.Request) {
		if f.beats.Add(1) > 1 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Write([]byte(`{"agent":{"id":"worker-a"}}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	token := filepath.Join(t.TempDir(), "captain.token")
	if err := os.WriteFile(token, []byte("test-captain-token-0123456789abcdef"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", token)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENT_ID", "worker-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	return server.URL, f
}

func runRosterCommand(args ...string) error {
	root := cli.NewRoot()
	root.SetArgs(args)
	return root.Execute()
}

func TestAgentRetireRequiresReason(t *testing.T) {
	newRosterBoard(t)
	err := runRosterCommand("agent", "retire", "worker-a")
	if err == nil || !strings.Contains(err.Error(), "--reason is required") {
		t.Fatalf("expected reason error, got %v", err)
	}
}

func TestAgentRetirePostsReasonAndForce(t *testing.T) {
	_, f := newRosterBoard(t)
	if err := runRosterCommand("agent", "retire", "worker-a", "--reason", "fixture cleanup", "--force"); err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(f.retire, &body); err != nil {
		t.Fatal(err)
	}
	if body["reason"] != "fixture cleanup" || body["force"] != true {
		t.Fatalf("unexpected retire body %s", f.retire)
	}
}

func TestAgentRestorePosts(t *testing.T) {
	newRosterBoard(t)
	if err := runRosterCommand("agent", "restore", "worker-a"); err != nil {
		t.Fatal(err)
	}
}

func TestAgentRegisterPassesKind(t *testing.T) {
	_, f := newRosterBoard(t)
	if err := runRosterCommand("agent", "register", "--name", "worker-a", "--kind", "human"); err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(f.register, &body); err != nil {
		t.Fatal(err)
	}
	if body["kind"] != "human" {
		t.Fatalf("expected kind human, got %s", f.register)
	}
}

func TestAgentRegisterRejectsUnknownKind(t *testing.T) {
	newRosterBoard(t)
	err := runRosterCommand("agent", "register", "--kind", "bot")
	if err == nil || !strings.Contains(err.Error(), "--kind must be seat, human, system, or fixture") {
		t.Fatalf("expected kind error, got %v", err)
	}
}

func TestHeartbeatEveryRejectsNegative(t *testing.T) {
	newRosterBoard(t)
	err := runRosterCommand("agent", "heartbeat", "--status", "busy", "--every", "-1s")
	if err == nil || !strings.Contains(err.Error(), "--every must be a positive duration") {
		t.Fatalf("expected duration error, got %v", err)
	}
}

func TestHeartbeatEveryTicksUntilError(t *testing.T) {
	_, f := newRosterBoard(t)
	// Second beat fails on the stub, which stops the ticker loop.
	err := runRosterCommand("agent", "heartbeat", "--status", "busy", "--every", "1ms")
	if err == nil {
		t.Fatal("expected ticker loop to surface the failing beat")
	}
	if f.beats.Load() != 2 {
		t.Fatalf("expected immediate beat plus one tick, got %d", f.beats.Load())
	}
}

// The register request and response remain byte-for-byte identity preserving;
// naming hints are advisory stderr output, including structured --json warnings.
func TestAgentRegistrationNamingHints(t *testing.T) {
	for _, tc := range []struct {
		id, harness string
		warn        bool
	}{
		{"agent-a", "codex", true},
		{"worker-1", "codex", true},
		{"legacy", "codex", true},
		{"legacy_id", "codex", true},
		{"agent--a", "codex", true},
		{"codex-agent-a", "codex", true},
		{"codex-worker-1", "codex", true},
		{"custom-harness-worker-1", "custom-harness", true},
		{"codex-serviceradar-agent-a", "codex", false},
		{"codex-agentboard-agent-b", "codex", false},
		{"claude-serviceradar-coordinator", "claude", false},
		{"codex-agent-a-server", "codex", false},
		{"codex-agent-b-worker", "codex", false},
		{"custom-repo_with_underscores-role", "custom", false},
		{"custom-multi-part-repo-role", "custom", false},
		// A spelling hint must not interpret or enforce an arbitrary prefix.
		{"unrelated-agent-a", "codex", false},
		{"codex-a-b", "codex", false},
	} {
		t.Run(tc.id, func(t *testing.T) {
			var calls atomic.Int32
			response := `{"agent":{"id":"` + tc.id + `","harness":"` + tc.harness + `"}}`
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/api/v1/meta" {
					io.WriteString(w, `{"api_version":1,"schema_version":33}`)
					return
				}
				if r.URL.Path != "/api/v1/agents/register" || r.Method != http.MethodPost {
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
				}
				if r.Header.Get("X-Agentboard-Agent") != tc.id || r.Header.Get("X-Agentboard-Harness") != tc.harness {
					t.Error("registration changed the supplied identity")
				}
				body, _ := io.ReadAll(r.Body)
				if string(body) != `{"name":"Friendly worker"}` {
					t.Errorf("registration payload changed: %s", body)
				}
				calls.Add(1)
				io.WriteString(w, response)
			}))
			defer server.Close()
			t.Setenv("AGENTBOARD_URL", server.URL)
			// Flags must take precedence over the environment for the hint too.
			t.Setenv("AGENT_ID", "other-repo-role")
			t.Setenv("AGENTBOARD_HARNESS", "other")
			t.Setenv("AGENTBOARD_MODEL", "fixture")
			for _, jsonOutput := range []bool{false, true} {
				root := cli.NewRoot()
				var stdout, stderr bytes.Buffer
				root.SetOut(&stdout)
				root.SetErr(&stderr)
				args := []string{"agent", "register", "--name", "Friendly worker", "--agent", tc.id, "--harness", tc.harness}
				if jsonOutput {
					args = append(args, "--json")
				}
				root.SetArgs(args)
				if err := root.Execute(); err != nil {
					t.Fatalf("legacy ID was rejected: %v", err)
				}
				if jsonOutput && stdout.String() != response+"\n" {
					t.Fatalf("JSON stdout changed: %q", stdout.String())
				}
				if !strings.Contains(stdout.String(), tc.id) {
					t.Fatalf("full identity missing from output %q", stdout.String())
				}
				if (stderr.Len() > 0) != tc.warn {
					t.Fatalf("warn=%t, stderr=%q", tc.warn, stderr.String())
				}
				if tc.warn {
					if !strings.Contains(stderr.String(), "advisory") || !strings.Contains(stderr.String(), tc.id) {
						t.Fatalf("missing advisory context: %q", stderr.String())
					}
					if jsonOutput {
						var warning struct{ Warning struct{ Code string } }
						if err := json.Unmarshal(stderr.Bytes(), &warning); err != nil || warning.Warning.Code != "agent_id_naming" {
							t.Fatalf("invalid structured warning: %q (%v)", stderr.String(), err)
						}
					}
				}
			}
			if calls.Load() != 2 {
				t.Fatalf("register was not sent once per invocation: %d", calls.Load())
			}
		})
	}
}

func TestAgentRegistrationFailureDoesNotPrintNamingHint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/meta" {
			io.WriteString(w, `{"api_version":1,"schema_version":33}`)
			return
		}
		w.WriteHeader(http.StatusConflict)
		io.WriteString(w, `{"error":{"code":"harness_conflict","message":"Harness cannot change"}}`)
	}))
	defer server.Close()
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENT_ID", "agent-a")
	t.Setenv("AGENTBOARD_HARNESS", "codex")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	root := cli.NewRoot()
	var stdout, stderr bytes.Buffer
	root.SetOut(&stdout)
	root.SetErr(&stderr)
	root.SetArgs([]string{"agent", "register", "--json"})
	if err := root.Execute(); err == nil || cli.ExitCode(err) != 4 {
		t.Fatalf("expected unchanged conflict error, got %v", err)
	}
	if stdout.Len() != 0 || stderr.Len() != 0 {
		t.Fatalf("failure printed success output or naming hint: %q %q", stdout.String(), stderr.String())
	}
}
