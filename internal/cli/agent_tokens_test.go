package cli_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
	"github.com/carverauto/agentboard/internal/client"
)

func tokenCommand(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	root := cli.NewRoot()
	var out, stderr bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&stderr)
	root.SetArgs(args)
	err := root.Execute()
	return out.String(), stderr.String(), err
}

func tokenActor(t *testing.T) {
	t.Helper()
	t.Setenv("AGENT_ID", "fixture-captain")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "codex")
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENTBOARD_TOKEN_FILE", "")
}

func TestParticipantGrantValidationPrecedesFilesAndNetwork(t *testing.T) {
	tokenActor(t)
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", "/missing-captain-credential")
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1) }))
	defer server.Close()
	t.Setenv("AGENTBOARD_URL", server.URL)
	tests := [][]string{
		{"--scope", "coordinator_participant"},
		{"--channel", "channel-1"},
		{"--scope", "agent", "--channel", "channel-1"},
		{"--scope", "coordinator", "--channel", "channel-1"},
		{"--scope", "unknown", "--channel", "channel-1"},
		{"--scope", "coordinator_participant", "--channel", ""},
		{"--scope", "coordinator_participant", "--channel", "one/two"},
		{"--scope", "coordinator_participant", "--channel", "one\n"},
		{"--scope", "coordinator_participant", "--channel", "é"},
		{"--scope", "coordinator_participant", "--channel", strings.Repeat("x", 129)},
		{"--scope", "coordinator_participant", "--channel", "one", "--channel", "one"},
	}
	oversized := []string{"--scope", "coordinator_participant"}
	for i := 0; i < 21; i++ {
		oversized = append(oversized, "--channel", "channel-"+strconv.Itoa(i))
	}
	tests = append(tests, oversized)
	for i, flags := range tests {
		t.Run(strconv.Itoa(i), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "token")
			args := append([]string{"agent", "token", "issue", "coordinator", "--out", path}, flags...)
			out, stderr, err := tokenCommand(t, args...)
			if err == nil || out != "" || strings.Contains(err.Error(), "CAPTAIN_TOKEN_FILE") || strings.Contains(stderr, "CAPTAIN_TOKEN_FILE") {
				t.Fatalf("grant was not rejected first: %v %q %q", err, out, stderr)
			}
			if _, err = os.Stat(path); !os.IsNotExist(err) {
				t.Fatalf("invalid grant touched output: %v", err)
			}
		})
	}
	if requests.Load() != 0 {
		t.Fatalf("invalid grants reached network: %d", requests.Load())
	}
}

func TestParticipantTokenCompatibilityAndSecretCustody(t *testing.T) {
	for _, schema := range []int{38, 39} {
		t.Run(strconv.Itoa(schema), func(t *testing.T) {
			tokenActor(t)
			dir := t.TempDir()
			capfile := filepath.Join(dir, "captain")
			capToken := "fixture-captain-token-0123456789abcdef"
			if err := os.WriteFile(capfile, []byte(capToken), 0600); err != nil {
				t.Fatal(err)
			}
			t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", capfile)
			issuedToken := "abt_" + strings.Repeat("a", 43)
			var mutations atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer "+capToken {
					t.Error("missing captain transport")
				}
				w.Header().Set("Content-Type", "application/json")
				if r.URL.Path == "/api/v1/meta" {
					io.WriteString(w, `{"api_version":1,"schema_version":`+strconv.Itoa(schema)+`}`)
					return
				}
				if r.URL.Path != "/api/v1/agents/coordinator/tokens/issue" {
					t.Errorf("unexpected path %s", r.URL.Path)
					w.WriteHeader(404)
					return
				}
				mutations.Add(1)
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				if body["scope"] != "coordinator_participant" {
					t.Errorf("unexpected scope %v", body)
				}
				channels, ok := body["channel_ids"].([]any)
				if !ok || len(channels) != 2 || channels[0] != "channel-1" || channels[1] != "channel-2" {
					t.Errorf("unexpected grant %v", body)
				}
				json.NewEncoder(w).Encode(map[string]any{"credential": map[string]any{"id": "fixture-id", "scope": "coordinator_participant", "channel_ids": channels}, "token": issuedToken})
			}))
			defer server.Close()
			t.Setenv("AGENTBOARD_URL", server.URL)
			outfile := filepath.Join(dir, "issued")
			out, stderr, err := tokenCommand(t, "agent", "token", "issue", "coordinator", "--out", outfile, "--scope", "coordinator_participant", "--channel", "channel-1", "--channel", "channel-2")
			if strings.Contains(out+stderr, issuedToken) || strings.Contains(out+stderr, capToken) {
				t.Fatal("secret escaped to command output")
			}
			if schema < 39 {
				var apiErr *client.Error
				if !errors.As(err, &apiErr) || apiErr.Code != "schema_unavailable" || mutations.Load() != 0 {
					t.Fatalf("legacy server accepted new scope: %v", err)
				}
				if _, err := os.Stat(outfile); !os.IsNotExist(err) {
					t.Fatal("incompatible issuance left credential file")
				}
			} else {
				if err != nil || mutations.Load() != 1 {
					t.Fatalf("issuance failed: %v %s", err, stderr)
				}
				data, err := os.ReadFile(outfile)
				if err != nil || string(data) != issuedToken+"\n" {
					t.Fatal("credential was not saved only to file")
				}
				stat, err := os.Stat(outfile)
				if err != nil || stat.Mode().Perm() != 0600 {
					t.Fatal("credential output not protected")
				}
				if !strings.Contains(out, `"channel_ids":["channel-1","channel-2"]`) {
					t.Fatalf("grant metadata missing %s", out)
				}
			}
		})
	}
}

func TestRunnerTokenRequiresExplicitScopeAndSchema40(t *testing.T) {
	for _, action := range []string{"issue", "rotate"} {
		for _, schema := range []int{39, 40, 41} {
			t.Run(action+"/"+strconv.Itoa(schema), func(t *testing.T) {
				tokenActor(t)
				dir := t.TempDir()
				capfile := filepath.Join(dir, "captain")
				captain := "synthetic-captain-capability-0123456789"
				if err := os.WriteFile(capfile, []byte(captain), 0600); err != nil {
					t.Fatal(err)
				}
				t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", capfile)
				issued := "abt_" + strings.Repeat("r", 43)
				var reads, writes atomic.Int32
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if r.Header.Get("Authorization") != "Bearer "+captain || r.Header.Get("X-Agentboard-Coordinator-Protocol") != "" {
						t.Error("runner issuance changed captain transport")
					}
					w.Header().Set("Content-Type", "application/json")
					if r.URL.Path == "/api/v1/meta" {
						reads.Add(1)
						io.WriteString(w, `{"api_version":1,"schema_version":`+strconv.Itoa(schema)+`}`)
						return
					}
					if r.Method != http.MethodPost || r.URL.Path != "/api/v1/agents/coordinator/tokens/"+action {
						t.Error("unexpected runner issuance operation")
					}
					writes.Add(1)
					body, err := io.ReadAll(r.Body)
					if err != nil || string(body) != `{"scope":"coordinator_runner"}` {
						t.Errorf("runner grant acquired unexpected fields: %s", body)
					}
					json.NewEncoder(w).Encode(map[string]any{"credential": map[string]any{"id": "fixture-runner", "scope": "coordinator_runner"}, "token": issued})
				}))
				defer server.Close()
				t.Setenv("AGENTBOARD_URL", server.URL)
				t.Setenv("AGENTBOARD_CA_FILE", "")
				t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
				outfile := filepath.Join(dir, "runner")
				out, stderr, err := tokenCommand(t, "agent", "token", action, "coordinator", "--scope", "coordinator_runner", "--out", outfile)
				if strings.Contains(out+stderr, issued) || strings.Contains(out+stderr, captain) || reads.Load() != 1 {
					t.Fatal("secret escaped or metadata preflight omitted")
				}
				if schema < 40 {
					var apiErr *client.Error
					if !errors.As(err, &apiErr) || apiErr.Code != "schema_unavailable" || writes.Load() != 0 {
						t.Fatalf("old server accepted runner: writes %d error %v", writes.Load(), err)
					}
					if _, err := os.Stat(outfile); !os.IsNotExist(err) {
						t.Fatal("incompatible issuance left credential output")
					}
				} else {
					data, readErr := os.ReadFile(outfile)
					info, statErr := os.Stat(outfile)
					if err != nil || writes.Load() != 1 || readErr != nil || string(data) != issued+"\n" || statErr != nil || info.Mode().Perm() != 0600 {
						t.Fatalf("runner issue/rotate failed: writes %d error %v", writes.Load(), err)
					}
				}
			})
		}
	}
}

func TestRunnerGrantCannotAcquireChannelsOrChangeOtherActions(t *testing.T) {
	tokenActor(t)
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", "/missing-captain-credential")
	for _, action := range []string{"issue", "rotate", "list", "revoke"} {
		args := []string{"agent", "token", action, "coordinator", "--scope", "coordinator_runner"}
		path := filepath.Join(t.TempDir(), "output")
		if action == "issue" || action == "rotate" {
			args = append(args, "--out", path, "--channel", "chat")
		}
		out, _, err := tokenCommand(t, args...)
		if err == nil || out != "" || strings.Contains(err.Error(), "CAPTAIN_TOKEN_FILE") {
			t.Fatalf("invalid runner grant reached credential access: %v", err)
		}
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatal("invalid grant touched output")
		}
	}
}

func TestCredentialDefaultDoesNotBecomeRunner(t *testing.T) {
	tokenActor(t)
	dir := t.TempDir()
	capfile := filepath.Join(dir, "captain")
	if err := os.WriteFile(capfile, []byte("fixture-captain-capability-0123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", capfile)
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		body, _ := io.ReadAll(r.Body)
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/agents/coordinator/tokens/issue" || string(body) != "{}" {
			t.Errorf("default credential grant changed: %s %s %s", r.Method, r.URL, body)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"credential": map[string]any{"scope": "coordinator"}, "token": "abt_" + strings.Repeat("d", 43)})
	}))
	defer server.Close()
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_CA_FILE", "")
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	if _, _, err := tokenCommand(t, "agent", "token", "issue", "coordinator", "--out", filepath.Join(dir, "output")); err != nil || calls.Load() != 1 {
		t.Fatalf("default issuance requests %d error %v", calls.Load(), err)
	}
}
