package cli_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
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
