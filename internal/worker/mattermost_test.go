package worker_test

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/worker"
)

var inboxFixture = worker.InboxItem{ID: "00000000-0000-4000-8000-000000000001", Version: strings.Repeat("a", 64)}

func TestMattermostExactReadsAndExplicitAck(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	cfg := workerFixture(t)
	var actions []string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		action := strings.TrimPrefix(r.URL.Path, "/api/v1/workers/worker-auth/")
		actions = append(actions, action)
		if r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer "+receiptTokenFixture {
			t.Error("missing scoped receipt capability or wrong method")
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		switch action {
		case "mattermost_read":
			if payload["id"] != inboxFixture.ID || payload["version"] != inboxFixture.Version || len(payload) != 2 {
				t.Errorf("wrong exact read payload: %v", payload)
			}
			io.WriteString(w, `{"protocol_revision":1,"items":[{"message":"source text","status":"source_unavailable"}]}`)
		case "mattermost_ack":
			raw, _ := json.Marshal(payload)
			want, _ := json.Marshal(map[string]any{"items": []worker.InboxItem{inboxFixture}})
			if string(raw) != string(want) {
				t.Errorf("wrong ack payload: %s", raw)
			}
			io.WriteString(w, `{"protocol_revision":1,"handled":["`+inboxFixture.ID+`"]}`)
		default:
			t.Errorf("unexpected side effect: %s", action)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	cfg.URL = server.URL
	cfg.CAFile = filepath.Join(t.TempDir(), "ca.pem")
	protectedFixture(t, cfg.CAFile, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})))
	api, err := worker.OpenAPI(cfg, cfg.Bindings[0], true)
	if err != nil {
		t.Fatal(err)
	}
	defer api.Close()
	for i := 0; i < 2; i++ {
		raw, err := api.MattermostRead(context.Background(), inboxFixture)
		if err != nil || !strings.Contains(string(raw), "source_unavailable") {
			t.Fatalf("source availability was lost: %s %v", raw, err)
		}
	}
	if !reflect.DeepEqual(actions, []string{"mattermost_read", "mattermost_read"}) {
		t.Fatalf("read implicitly handled source: %v", actions)
	}
	for i := 0; i < 2; i++ {
		if _, err := api.MattermostAck(context.Background(), []worker.InboxItem{inboxFixture}); err != nil {
			t.Fatal(err)
		}
	}
	if !reflect.DeepEqual(actions, []string{"mattermost_read", "mattermost_read", "mattermost_ack", "mattermost_ack"}) {
		t.Fatalf("unexpected routes %v", actions)
	}
}

func TestMattermostInvalidItemsNeverReachHTTP(t *testing.T) {
	// A nil API is deliberate: malformed input must fail before any transport.
	var api *worker.API
	for _, item := range []worker.InboxItem{
		{}, {ID: "not-a-uuid", Version: inboxFixture.Version}, {ID: inboxFixture.ID, Version: ""},
		{ID: inboxFixture.ID, Version: strings.Repeat("A", 64)}, {ID: inboxFixture.ID, Version: strings.Repeat("g", 64)},
		{ID: "--------0000-4000-8000-000000000001", Version: inboxFixture.Version},
	} {
		if _, err := api.MattermostRead(context.Background(), item); err == nil {
			t.Fatal("malformed read accepted")
		}
		if _, err := api.MattermostAck(context.Background(), []worker.InboxItem{item}); err == nil {
			t.Fatal("malformed acknowledgement accepted")
		}
	}
	for _, items := range [][]worker.InboxItem{nil, {}, {inboxFixture, inboxFixture}, make([]worker.InboxItem, 51)} {
		if _, err := api.MattermostAck(context.Background(), items); err == nil {
			t.Fatal("unbounded/duplicate acknowledgement accepted")
		}
	}
}
