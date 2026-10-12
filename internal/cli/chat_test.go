package cli_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

type chatBoard struct {
	sends    atomic.Int32
	reads    atomic.Int32
	lastSend map[string]any
	server   *httptest.Server
}

func newChatBoard(t *testing.T) *chatBoard {
	t.Helper()
	f := &chatBoard{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"api_version":1,"schema_version":12,"required_schema_version":12}`))
	})
	mux.HandleFunc("POST /api/v1/conversations/send", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Agentboard-Agent") == "" {
			w.WriteHeader(422)
			return
		}
		f.sends.Add(1)
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			w.WriteHeader(400)
			return
		}
		if payload["channel_id"] == "" || payload["body"] == "" {
			w.WriteHeader(422)
			w.Write([]byte(`{"error":{"code":"invalid_input","message":"channel_id and body required"}}`))
			return
		}
		f.lastSend = payload
		w.WriteHeader(200)
		json.NewEncoder(w).Encode(map[string]any{
			"duplicate": false,
			"post":      map[string]any{"id": "post-1", "channel_id": payload["channel_id"]},
			"msg_id":    "msg-1",
		})
	})
	mux.HandleFunc("GET /api/v1/conversations/reads", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Agentboard-Agent") == "" {
			w.WriteHeader(422)
			return
		}
		f.reads.Add(1)
		q := r.URL.Query()
		if q.Get("channel_id") == "" {
			w.WriteHeader(422)
			return
		}
		w.WriteHeader(200)
		json.NewEncoder(w).Encode(map[string]any{
			"channel_id":        q.Get("channel_id"),
			"posts":             []any{map[string]any{"id": "post-1"}},
			"caught_up":         q.Get("since") != "",
			"incomplete_reason": nil,
		})
	})
	f.server = httptest.NewServer(mux)
	t.Cleanup(f.server.Close)
	return f
}

func runChatCommand(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	root := cli.NewRoot()
	var stdout, stderr bytes.Buffer
	root.SetOut(&stdout)
	root.SetErr(&stderr)
	root.SetArgs(args)
	err := root.Execute()
	return stdout.String(), stderr.String(), err
}

func TestChatSendRequiresAgentAndChannel(t *testing.T) {
	f := newChatBoard(t)
	t.Setenv("AGENTBOARD_URL", f.server.URL)
	t.Setenv("AGENT_ID", "")
	if _, _, err := runChatCommand(t, "chat", "send", "--channel", "chan-1", "--body", "hi"); err == nil {
		t.Fatal("expected actor validation error without AGENT_ID")
	}
	t.Setenv("AGENT_ID", "worker-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	if _, _, err := runChatCommand(t, "chat", "send", "--body", "hi"); err == nil {
		t.Fatal("expected channel requirement error")
	}
}

func TestChatSendPostsThroughAPI(t *testing.T) {
	f := newChatBoard(t)
	t.Setenv("AGENTBOARD_URL", f.server.URL)
	t.Setenv("AGENT_ID", "worker-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	out, stderr, err := runChatCommand(t, "chat", "send", "--channel", "chan-1", "--body", "hello agents",
		"--task", "task-1", "--kind", "status", "--retry-key", "key-1", "--json")
	if err != nil {
		t.Fatalf("send failed: %v stderr %s", err, stderr)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatalf("invalid output %s: %v", out, err)
	}
	if envelope["duplicate"] != false {
		t.Fatalf("expected fresh post, got %v", envelope)
	}
	if f.sends.Load() != 1 {
		t.Fatalf("expected one API send, got %d", f.sends.Load())
	}
	if f.lastSend["retry_key"] != "key-1" || f.lastSend["kind"] != "status" {
		t.Fatalf("send payload lost fields: %v", f.lastSend)
	}
}

func TestChatSendTableShowsDuplicate(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"api_version":1,"schema_version":12}`))
	})
	mux.HandleFunc("POST /api/v1/conversations/send", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"duplicate":true,"post":{"id":"post-0"}}`))
	})
	server := httptest.NewServer(mux)
	defer server.Close()
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENT_ID", "worker-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	out, _, err := runChatCommand(t, "chat", "send", "--channel", "chan-1", "--body", "again", "--retry-key", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "duplicate") {
		t.Fatalf("expected duplicate marker in table output: %q", out)
	}
}

func TestChatReadFetchesThroughAPI(t *testing.T) {
	f := newChatBoard(t)
	t.Setenv("AGENTBOARD_URL", f.server.URL)
	t.Setenv("AGENT_ID", "worker-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	out, _, err := runChatCommand(t, "chat", "read", "--channel", "chan-1", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope["caught_up"] != false {
		t.Fatalf("expected bounded snapshot without cursor, got %v", envelope)
	}
	out, _, err = runChatCommand(t, "chat", "read", "--channel", "chan-1", "--since", "post-0", "--json")
	if err != nil {
		t.Fatal(err)
	}
	envelope = nil
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope["caught_up"] != true {
		t.Fatalf("expected caught-up with cursor, got %v", envelope)
	}
	if f.reads.Load() != 2 {
		t.Fatalf("expected two API reads, got %d", f.reads.Load())
	}
}

// spoolBoard stands in for a schema-43 server with spooled sends and private
// recipient routes. It records exactly what the CLI asked for.
type spoolBoard struct {
	server   *httptest.Server
	lastSend map[string]any
	lastRead string
	resolved map[string]any
	state    string
}

func newSpoolBoard(t *testing.T, schema int) *spoolBoard {
	t.Helper()
	f := &spoolBoard{state: "uncertain"}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"api_version": 1, "schema_version": schema})
	})
	mux.HandleFunc("POST /api/v1/conversations/send", func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&f.lastSend)
		w.WriteHeader(http.StatusAccepted)
		json.NewEncoder(w).Encode(map[string]any{
			"duplicate": false, "post": nil, "msg_id": "msg-9", "state": f.state,
			"reason": "post_not_observed", "spool": map[string]any{"msg_id": "msg-9", "state": f.state},
		})
	})
	mux.HandleFunc("GET /api/v1/conversations/reads", func(w http.ResponseWriter, r *http.Request) {
		f.lastRead = r.URL.RawQuery
		json.NewEncoder(w).Encode(map[string]any{"channel_id": "route-1", "posts": []any{}, "caught_up": false, "incomplete_reason": "no_posts"})
	})
	mux.HandleFunc("GET /api/v1/conversations/sends/{id}", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"send": map[string]any{"msg_id": r.PathValue("id"), "state": "sent", "post_id": "post-4"}})
	})
	mux.HandleFunc("POST /api/v1/conversations/sends/{id}/resolve", func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&f.resolved)
		json.NewEncoder(w).Encode(map[string]any{"msg_id": r.PathValue("id"), "state": "abandoned", "duplicate": false})
	})
	f.server = httptest.NewServer(mux)
	t.Cleanup(f.server.Close)
	return f
}

func spoolEnv(t *testing.T, url string) {
	t.Setenv("AGENTBOARD_URL", url)
	t.Setenv("AGENT_ID", "worker-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
}

func TestChatSendUnresolvedReceiptExitsFive(t *testing.T) {
	f := newSpoolBoard(t, 43)
	spoolEnv(t, f.server.URL)
	out, _, err := runChatCommand(t, "chat", "send", "--to", "worker-b", "--body", "private", "--retry-key", "k-1", "--json")
	if cli.ExitCode(err) != 5 {
		t.Fatalf("uncertain receipt must exit 5, got %v (%d)", err, cli.ExitCode(err))
	}
	var receipt map[string]any
	if json.Unmarshal([]byte(out), &receipt) != nil || receipt["state"] != "uncertain" || receipt["msg_id"] != "msg-9" {
		t.Fatalf("receipt must still print machine-readably: %q", out)
	}
	if f.lastSend["to"] != "worker-b" || f.lastSend["channel_id"] != nil {
		t.Fatalf("--to must address the recipient, never a channel: %v", f.lastSend)
	}
	var stderr bytes.Buffer
	root := cli.NewRoot()
	if err := root.PersistentFlags().Set("json", "true"); err != nil {
		t.Fatal(err)
	}
	cli.PrintError(root, &stderr, err)
	if !strings.Contains(stderr.String(), `"send_unresolved"`) {
		t.Fatalf("stderr must carry the send_unresolved code: %q", stderr.String())
	}
	f.state = "sent"
	if _, _, err := runChatCommand(t, "chat", "send", "--to", "worker-b", "--body", "private", "--json"); err != nil {
		t.Fatalf("a verified receipt exits 0: %v", err)
	}
}

func TestChatSendRequiresExactlyOneDestination(t *testing.T) {
	f := newSpoolBoard(t, 43)
	spoolEnv(t, f.server.URL)
	if _, _, err := runChatCommand(t, "chat", "send", "--channel", "c", "--to", "worker-b", "--body", "x"); err == nil {
		t.Fatal("--channel with --to must be rejected")
	}
	if _, _, err := runChatCommand(t, "chat", "read", "--channel", "c", "--inbox"); err == nil {
		t.Fatal("--channel with --inbox must be rejected")
	}
	if f.lastSend != nil || f.lastRead != "" {
		t.Fatal("invalid flags must not reach the API")
	}
}

func TestChatPrivateRouteNeedsSchema43(t *testing.T) {
	f := newSpoolBoard(t, 42)
	spoolEnv(t, f.server.URL)
	_, _, err := runChatCommand(t, "chat", "send", "--to", "worker-b", "--body", "x")
	if err == nil || !strings.Contains(err.Error(), "incompatible") {
		t.Fatalf("schema 42 server must refuse --to before sending: %v", err)
	}
	if _, _, err := runChatCommand(t, "chat", "read", "--inbox"); err == nil {
		t.Fatal("schema 42 server must refuse --inbox")
	}
	if f.lastSend != nil || f.lastRead != "" {
		t.Fatal("refused commands must not reach the API")
	}
}

func TestChatInboxStatusAndResolve(t *testing.T) {
	f := newSpoolBoard(t, 43)
	spoolEnv(t, f.server.URL)
	if _, _, err := runChatCommand(t, "chat", "read", "--inbox", "--json"); err != nil {
		t.Fatal(err)
	}
	if f.lastRead != "inbox=true&limit=50" {
		t.Fatalf("inbox read must not name a channel: %q", f.lastRead)
	}
	out, _, err := runChatCommand(t, "chat", "status", "--msg-id", "msg-4", "--json")
	if err != nil || !strings.Contains(out, `"post_id":"post-4"`) {
		t.Fatalf("status must print the receipt: %q %v", out, err)
	}
	if _, _, err := runChatCommand(t, "chat", "resolve", "--msg-id", "msg-4", "--action", "drop"); err == nil {
		t.Fatal("unknown resolve actions are rejected locally")
	}
	out, _, err = runChatCommand(t, "chat", "resolve", "--msg-id", "msg-4", "--action", "abandon", "--json")
	if err != nil || f.resolved["action"] != "abandon" || !strings.Contains(out, `"abandoned"`) {
		t.Fatalf("resolve must send the explicit action: %q %v %v", out, err, f.resolved)
	}
}
