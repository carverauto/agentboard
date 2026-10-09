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

const scopeCaptain = "fixture-scope-captain-0123456789abcdef"
const scopeResponse = `{"scope":{"agent_id":"worker-a","state":"managed","revision":1,"allowed_repos":["owner/repo"],"required_labels":[],"allowed_labels":[],"changed_by":"captain","updated_at":"2026-10-09T00:00:00Z"}}`

func scopeServer(t *testing.T, schema int, handler http.HandlerFunc) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/meta" {
			fmt.Fprintf(w, `{"api_version":1,"schema_version":%d}`, schema)
			return
		}
		if r.URL.Path != "/api/v1/agents/worker-a/scope" {
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	token := filepath.Join(t.TempDir(), "captain.token")
	if err := os.WriteFile(token, []byte(scopeCaptain+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENT_ID", "captain")
	t.Setenv("AGENTBOARD_MODEL", "human")
	t.Setenv("AGENTBOARD_HARNESS", "captain")
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENTBOARD_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", token)
	return token
}

func scopeCommand(args ...string) (string, error) {
	root := cli.NewRoot()
	var output bytes.Buffer
	root.SetOut(&output)
	root.SetArgs(args)
	err := root.Execute()
	return output.String(), err
}

func TestScopeShowSupportsJSONAndTextWithoutCaptain(t *testing.T) {
	for _, jsonMode := range []bool{false, true} {
		t.Run(fmt.Sprint(jsonMode), func(t *testing.T) {
			scopeServer(t, 34, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.Header.Get("Authorization") != "" {
					t.Errorf("unexpected scope show method/auth %s %q", r.Method, r.Header.Get("Authorization"))
				}
				fmt.Fprint(w, scopeResponse)
			})
			t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", "")
			args := []string{"agent", "scope", "show", "worker-a"}
			if jsonMode {
				args = append(args, "--json")
			}
			output, err := scopeCommand(args...)
			if err != nil || !strings.Contains(output, `"allowed_repos":["owner/repo"]`) || !strings.Contains(output, `"state":"managed"`) {
				t.Fatalf("output %q error %v", output, err)
			}
			if jsonMode && !strings.Contains(output, `"scope":`) {
				t.Fatalf("missing scope envelope: %s", output)
			}
		})
	}
}

func TestScopeSetFullReplacementAndCaptainTransport(t *testing.T) {
	for _, labels := range []bool{false, true} {
		t.Run(fmt.Sprint(labels), func(t *testing.T) {
			calls := 0
			scopeServer(t, 34, func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Method != http.MethodPut || r.Header.Get("Authorization") != "Bearer "+scopeCaptain || r.Header.Get("X-Agentboard-Worker-Protocol") != "" {
					t.Error("scope set did not use captain HTTP transport")
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				required, allowed := []any{}, []any{}
				if labels {
					required = []any{"Security, Review", "Ready"}
					allowed = []any{"Backend", "UI"}
				}
				want := map[string]any{"revision": float64(0), "allowed_repos": []any{"Owner/Repo", "owner/other"}, "required_labels": required, "allowed_labels": allowed}
				if !reflect.DeepEqual(body, want) {
					t.Errorf("scope replacement %v; want %v", body, want)
				}
				fmt.Fprint(w, scopeResponse)
			})
			args := []string{"agent", "scope", "set", "worker-a", "--repo", "Owner/Repo", "--repo", "owner/other", "--revision", "0"}
			if labels {
				args = append(args, "--required-label", "Security, Review", "--required-label", "Ready", "--allowed-label", "Backend", "--allowed-label", "UI")
			}
			output, err := scopeCommand(args...)
			if err != nil || calls != 1 || strings.Contains(output, scopeCaptain) {
				t.Fatalf("scope set calls %d output %q error %v", calls, output, err)
			}
		})
	}
}

func TestScopeSetValidatesRequiredFieldsBeforeRequest(t *testing.T) {
	for _, flags := range [][]string{{"--repo", "owner/repo"}, {"--revision", "-1", "--repo", "owner/repo"}, {"--revision", "0"}, {"--revision", "0", "--repo", " "}} {
		t.Run(strings.Join(flags, " "), func(t *testing.T) {
			scopeServer(t, 34, func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected scope request") })
			output, err := scopeCommand(append([]string{"agent", "scope", "set", "worker-a"}, flags...)...)
			if err == nil || output != "" {
				t.Fatalf("expected validation error, got output %q error %v", output, err)
			}
		})
	}
}

func TestScopeRequiresSchema34(t *testing.T) {
	for _, args := range [][]string{{"show", "worker-a"}, {"set", "worker-a", "--revision", "0", "--repo", "owner/repo"}} {
		t.Run(args[0], func(t *testing.T) {
			scopeServer(t, 33, func(w http.ResponseWriter, r *http.Request) { t.Error("requested unsupported scope endpoint") })
			output, err := scopeCommand(append([]string{"agent", "scope"}, args...)...)
			if err == nil || !strings.Contains(err.Error(), "incompatible") || output != "" {
				t.Fatalf("expected schema error, got %q %v", output, err)
			}
		})
	}
}

func TestScopeSetRejectsUnprotectedCaptainFile(t *testing.T) {
	token := scopeServer(t, 34, func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected scope request") })
	if err := os.Chmod(token, 0644); err != nil {
		t.Fatal(err)
	}
	output, err := scopeCommand("agent", "scope", "set", "worker-a", "--revision", "0", "--repo", "owner/repo")
	if err == nil || !strings.Contains(err.Error(), "protected captain") || output != "" {
		t.Fatalf("expected protected file error, got %q %v", output, err)
	}
}

func TestScopeStaleRevisionIsNotRetried(t *testing.T) {
	calls := 0
	scopeServer(t, 34, func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error":{"code":"conflict","message":"Scope revision has changed"}}`)
	})
	output, err := scopeCommand("agent", "scope", "set", "worker-a", "--revision", "1", "--repo", "owner/repo")
	if err == nil || cli.ExitCode(err) != 4 || calls != 1 || output != "" {
		t.Fatalf("expected one conflict, got calls %d output %q error %v", calls, output, err)
	}
}
