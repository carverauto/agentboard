package cli_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
	"github.com/carverauto/agentboard/internal/client"
)

const hostileBody = "line one\nline two \"quoted\" <script>alert(1)</script> & \\ back sep\ttab 🙂"

func exportServer(t *testing.T, meta string, handler http.HandlerFunc) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/meta" {
			fmt.Fprint(w, meta)
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENTBOARD_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENT_ID", "fixture-exporter")
	t.Setenv("AGENTBOARD_MODEL", "fixture-model")
	t.Setenv("AGENTBOARD_HARNESS", "codex")
}

func runExport(args ...string) (string, error) {
	root := cli.NewRoot()
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(append([]string{"msg", "export"}, args...))
	err := root.Execute()
	return out.String(), err
}

const exportMeta = `{"api_version":1,"schema_version":42,"message_history":{"export_supported":true}}`

func exportPage(t *testing.T, w http.ResponseWriter, next any, bodies ...string) {
	t.Helper()
	records := make([]map[string]any, 0, len(bodies))
	for i, body := range bodies {
		records = append(records, map[string]any{"id": i + 1, "body": body, "task_id": "history-task"})
	}
	// Pretty-printed pages prove the CLI compacts each record onto one line.
	encoded, err := json.MarshalIndent(map[string]any{"messages": records, "next_cursor": next}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w.Write(encoded)
}

func TestMessageExportWritesOneEscapedRecordPerLineAcrossPages(t *testing.T) {
	var requests []string
	exportServer(t, exportMeta, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/messages/export" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL)
			return
		}
		requests = append(requests, r.URL.RawQuery)
		if r.URL.Query().Get("cursor") == "" {
			exportPage(t, w, "page-2", hostileBody, "second")
			return
		}
		exportPage(t, w, nil, "third")
	})
	out, err := runExport("--task", "history-task", "--page-size", "2")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(requests, "|") != "limit=2&task=history-task|cursor=page-2&limit=2&task=history-task" {
		t.Fatalf("unexpected page requests %q", requests)
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(lines) != 3 || !strings.HasSuffix(out, "\n") {
		t.Fatalf("want three NDJSON lines, got %q", out)
	}
	want := []string{hostileBody, "second", "third"}
	for i, line := range lines {
		var record map[string]any
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			t.Fatalf("line %d is not JSON: %q", i, line)
		}
		if record["body"] != want[i] {
			t.Fatalf("line %d body %q, want %q", i, record["body"], want[i])
		}
	}
}

func TestMessageExportFailureNamesResumeCursorAndKeepsCompletePages(t *testing.T) {
	exportServer(t, exportMeta, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("cursor") == "" {
			exportPage(t, w, "page-2", "first")
			return
		}
		w.WriteHeader(http.StatusUnprocessableEntity)
		fmt.Fprint(w, `{"error":{"code":"invalid_input","message":"Cursor does not match this query"}}`)
	})
	out, err := runExport("--page-size", "1")
	if err == nil || !strings.Contains(err.Error(), "resume with --cursor page-2") {
		t.Fatalf("want resumable failure, got %v", err)
	}
	if cli.ExitCode(err) != 2 {
		t.Fatalf("exit code %d", cli.ExitCode(err))
	}
	if strings.Count(out, "\n") != 1 || !strings.Contains(out, `"first"`) {
		t.Fatalf("only the completed page may be written, got %q", out)
	}
}

func TestMessageExportRequiresAdvertisedSupport(t *testing.T) {
	exportServer(t, `{"api_version":1,"schema_version":42}`, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("unsupported server must not be read: %s", r.URL)
	})
	_, err := runExport()
	var apiErr *client.Error
	if !errors.As(err, &apiErr) || apiErr.Code != "schema_unavailable" {
		t.Fatalf("want schema_unavailable, got %v", err)
	}
	if _, err = runExport("--page-size", "1001"); err == nil {
		t.Fatal("page size above the API bound must be refused locally")
	}
}

func TestLegacySendMigrationRefusalIsTypedConflict(t *testing.T) {
	exportServer(t, exportMeta, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error":{"code":"message_transport_migrated","message":"Board message sends are retired in mattermost mode; use `+"`agentboard chat send`"+`.","migration":{"command":"agentboard chat send"}}}`)
	})
	root := cli.NewRoot()
	var stderr bytes.Buffer
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&stderr)
	root.SetArgs([]string{"--json", "msg", "send", "--to", "peer", "--body", "hello"})
	err := root.Execute()
	if cli.ExitCode(err) != 4 {
		t.Fatalf("exit code %d for %v", cli.ExitCode(err), err)
	}
	cli.PrintError(root, &stderr, err)
	var envelope struct {
		Error struct{ Code, Message string } `json:"error"`
	}
	if json.Unmarshal(stderr.Bytes(), &envelope) != nil || envelope.Error.Code != "message_transport_migrated" || !strings.Contains(envelope.Error.Message, "agentboard chat send") {
		t.Fatalf("unexpected JSON error %q", stderr.String())
	}
}
