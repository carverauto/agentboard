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
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
	"github.com/carverauto/agentboard/internal/client"
)

func TestMetaUsesAPIWithoutDatabaseCredentials(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/meta" || r.Method != "GET" {
			w.WriteHeader(404)
			return
		}
		if calls.Add(1) == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(429)
			return
		}
		io.WriteString(w, `{"api_version":1,"schema_version":null,"required_schema_version":1}`)
	}))
	defer server.Close()
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_DATABASE_URL", "")
	root := cli.NewRoot()
	var stdout, stderr bytes.Buffer
	root.SetOut(&stdout)
	root.SetErr(&stderr)
	root.SetArgs([]string{"meta"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	var record map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &record); err != nil {
		t.Fatalf("invalid output %s: %v", stdout.String(), err)
	}
	if record["api_version"] != float64(1) || calls.Load() != 2 || stderr.Len() != 0 {
		t.Fatalf("record %v calls %d stderr %q", record, calls.Load(), stderr.String())
	}
}

func TestRejectedRequestLeavesCLIStdoutEmpty(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "999")
		w.WriteHeader(429)
	}))
	defer server.Close()
	t.Setenv("AGENTBOARD_URL", server.URL)
	root := cli.NewRoot()
	var stdout bytes.Buffer
	root.SetOut(&stdout)
	root.SetArgs([]string{"meta"})
	err := root.Execute()
	if cli.ExitCode(err) != 1 || stdout.Len() != 0 {
		t.Fatalf("error %v stdout %q", err, stdout.String())
	}
}

// Legacy servers may ignore new auth headers or filters. Feature commands must
// reject incompatible schemas before any mutation or misleading roster read.
func TestFeatureCommandsRequireCompatibleServer(t *testing.T) {
	for _, schema := range []string{"12", "14", "15", "19"} {
		for _, feature := range []struct {
			minimum int
			args    []string
		}{
			{15, []string{"task", "assign", "fixture-task", "--to", "fixture-agent", "--captain"}},
			{15, []string{"agent", "list", "--availability", "active"}},
			{15, []string{"msg", "send", "--to", "fixture-agent", "--kind", "task_order", "--body", "Work order"}},
			{15, []string{"agent", "availability", "set", "--agent-id", "fixture-agent", "--state", "active"}},
			{20, []string{"decision", "list"}},
			{20, []string{"decision", "answer", "00000000-0000-4000-8000-000000000001", "--answer", "Approved"}},
			{20, []string{"decision", "ack", "00000000-0000-4000-8000-000000000001"}},
			{20, []string{"agent", "list", "--waiting", "true"}},
		} {
			version, _ := strconv.Atoi(schema)
			if version >= feature.minimum {
				continue
			}
			args := feature.args
			t.Run(schema+"-"+args[0]+"-"+args[1], func(t *testing.T) {
				var requests atomic.Int32
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("Content-Type", "application/json")
					if r.URL.Path == "/api/v1/meta" {
						io.WriteString(w, `{"api_version":1,"schema_version":`+schema+`}`)
						return
					}
					requests.Add(1)
					io.WriteString(w, `{"task":{"id":"fixture-task"}}`)
				}))
				defer server.Close()
				tokenPath := filepath.Join(t.TempDir(), "captain-token")
				if err := os.WriteFile(tokenPath, []byte("fixture-captain-token-0123456789abcdef"), 0600); err != nil {
					t.Fatal(err)
				}
				t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", tokenPath)
				t.Setenv("AGENTBOARD_URL", server.URL)
				t.Setenv("AGENT_ID", "fixture-coordinator")
				t.Setenv("AGENTBOARD_MODEL", "fixture-model")
				t.Setenv("AGENTBOARD_HARNESS", "codex")
				root := cli.NewRoot()
				var output bytes.Buffer
				root.SetOut(&output)
				root.SetArgs(append([]string{"--json"}, args...))
				err := root.Execute()
				var apiError *client.Error
				if !errors.As(err, &apiError) || apiError.Code != "schema_unavailable" || requests.Load() != 0 || output.Len() != 0 {
					t.Fatalf("legacy feature call not fenced: error=%v requests=%d stdout=%q", err, requests.Load(), output.String())
				}
			})
		}
	}
}
