package cli_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

type mmFixture struct {
	token   string
	selfID  string
	posts   map[string]map[string]any
	order   []string
	created atomic.Int32
	server  *httptest.Server
}

func newMMFixture(t *testing.T) *mmFixture {
	t.Helper()
	f := &mmFixture{
		token:  "worker-token-abc123",
		selfID: "mm-self",
		posts: map[string]map[string]any{
			"post-old": {"id": "post-old", "channel_id": "chan-1", "user_id": "mm-peer", "message": "hello", "props": map[string]any{}},
			"post-own": {"id": "post-own", "channel_id": "chan-1", "user_id": "mm-self", "message": "my echo", "props": map[string]any{}},
		},
		order: []string{"post-own", "post-old"},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v4/users/me", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+f.token {
			w.WriteHeader(401)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"id": f.selfID, "username": "worker-a"})
	})
	mux.HandleFunc("GET /api/v4/channels/chan-1/posts", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+f.token {
			w.WriteHeader(401)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"order": f.order, "posts": f.posts})
	})
	mux.HandleFunc("POST /api/v4/posts", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+f.token {
			w.WriteHeader(401)
			return
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			w.WriteHeader(400)
			return
		}
		n := f.created.Add(1)
		post := map[string]any{
			"id":         "post-new",
			"channel_id": payload["channel_id"],
			"user_id":    f.selfID,
			"message":    payload["message"],
			"props":      payload["props"],
		}
		f.posts["post-new"] = post
		f.order = append([]string{"post-new"}, f.order...)
		w.WriteHeader(201)
		json.NewEncoder(w).Encode(post)
		_ = n
	})
	f.server = httptest.NewServer(mux)
	t.Cleanup(f.server.Close)
	return f
}

func writeTokenFile(t *testing.T, token string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "worker-token")
	if err := os.WriteFile(path, []byte(token+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func runChat(t *testing.T, args ...string) (string, error) {
	t.Helper()
	root := cli.NewRoot()
	var stdout, stderr bytes.Buffer
	root.SetOut(&stdout)
	root.SetErr(&stderr)
	root.SetArgs(args)
	err := root.Execute()
	if stderr.Len() != 0 && err == nil {
		t.Fatalf("unexpected stderr %q", stderr.String())
	}
	return stdout.String(), err
}

func TestChatSendRequiresActor(t *testing.T) {
	t.Setenv("AGENT_ID", "")
	if _, err := runChat(t, "chat", "send", "--channel", "chan-1", "--body", "hi"); err == nil {
		t.Fatal("expected actor validation error")
	}
}

func TestChatSendRequiresTokenFile(t *testing.T) {
	f := newMMFixture(t)
	t.Setenv("AGENTBOARD_MATTERMOST_BASE_URL", f.server.URL)
	t.Setenv("AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE", filepath.Join(t.TempDir(), "missing"))
	t.Setenv("AGENT_ID", "test-worker")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	if _, err := runChat(t, "chat", "send", "--channel", "chan-1", "--body", "hi"); err == nil {
		t.Fatal("expected token file error")
	}
}

func TestChatSendPostsAndNeverLeaksToken(t *testing.T) {
	f := newMMFixture(t)
	t.Setenv("AGENTBOARD_MATTERMOST_BASE_URL", f.server.URL)
	t.Setenv("AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE", writeTokenFile(t, f.token))
	t.Setenv("AGENT_ID", "test-worker")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	out, err := runChat(t, "chat", "send", "--channel", "chan-1", "--body", "hello agents", "--json")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, f.token) {
		t.Fatalf("token leaked into output: %s", out)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatalf("invalid output %s: %v", out, err)
	}
	record, _ := envelope["chat"].(map[string]any)
	if record["duplicate"] != false {
		t.Fatalf("expected fresh post, got %v", record)
	}
	post, _ := record["post"].(map[string]any)
	if post["id"] != "post-new" || f.created.Load() != 1 {
		t.Fatalf("expected one created post, got %v", record)
	}
}

func TestChatSendRetryKeyAdoptsDuplicate(t *testing.T) {
	f := newMMFixture(t)
	t.Setenv("AGENTBOARD_MATTERMOST_BASE_URL", f.server.URL)
	t.Setenv("AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE", writeTokenFile(t, f.token))
	t.Setenv("AGENT_ID", "test-worker")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	out, err := runChat(t, "chat", "send", "--channel", "chan-1", "--body", "first", "--retry-key", "key-1", "--json")
	if err != nil {
		t.Fatal(err)
	}
	out, err = runChat(t, "chat", "send", "--channel", "chan-1", "--body", "second", "--retry-key", "key-1", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatal(err)
	}
	record, _ := envelope["chat"].(map[string]any)
	if record["duplicate"] != true {
		t.Fatalf("expected duplicate adoption, got %v", record)
	}
	if f.created.Load() != 1 {
		t.Fatalf("expected exactly one Mattermost post, created %d", f.created.Load())
	}
}

func TestChatReadSuppressesOwnEcho(t *testing.T) {
	f := newMMFixture(t)
	t.Setenv("AGENTBOARD_MATTERMOST_BASE_URL", f.server.URL)
	t.Setenv("AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE", writeTokenFile(t, f.token))
	t.Setenv("AGENT_ID", "")
	out, err := runChat(t, "chat", "read", "--channel", "chan-1", "--json")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, f.token) {
		t.Fatalf("token leaked into output: %s", out)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatal(err)
	}
	record, _ := envelope["chat"].(map[string]any)
	posts, _ := record["posts"].([]any)
	if len(posts) != 1 {
		t.Fatalf("expected only the peer post, got %v", record)
	}
	if posts[0].(map[string]any)["id"] != "post-old" {
		t.Fatalf("expected oldest-first peer post, got %v", posts)
	}
	if record["caught_up"] != false || record["incomplete_reason"] != "bounded_snapshot" {
		t.Fatalf("expected explicit bounded snapshot state, got %v", record)
	}
}

func TestChatReadSinceCursorMarksCaughtUp(t *testing.T) {
	f := newMMFixture(t)
	t.Setenv("AGENTBOARD_MATTERMOST_BASE_URL", f.server.URL)
	t.Setenv("AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE", writeTokenFile(t, f.token))
	t.Setenv("AGENT_ID", "")
	out, err := runChat(t, "chat", "read", "--channel", "chan-1", "--since", "post-old", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatal(err)
	}
	record, _ := envelope["chat"].(map[string]any)
	if record["caught_up"] != true || record["incomplete_reason"] != nil {
		t.Fatalf("expected caught-up with no reason, got %v", record)
	}
}

func TestChatReadMissingCursorStaysExplicit(t *testing.T) {
	f := newMMFixture(t)
	t.Setenv("AGENTBOARD_MATTERMOST_BASE_URL", f.server.URL)
	t.Setenv("AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE", writeTokenFile(t, f.token))
	t.Setenv("AGENT_ID", "")
	out, err := runChat(t, "chat", "read", "--channel", "chan-1", "--since", "post-gone", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatal(err)
	}
	record, _ := envelope["chat"].(map[string]any)
	if record["caught_up"] != false || record["incomplete_reason"] != "cursor_not_found" {
		t.Fatalf("expected explicit cursor gap, got %v", record)
	}
}
