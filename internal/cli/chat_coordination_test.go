package cli_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// coordinationBoard serves meta with or without a coordination channel and
// records the channel each send or read reached.
func coordinationBoard(t *testing.T, channel string) (*httptest.Server, *[]string) {
	t.Helper()
	var reached []string
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		meta := map[string]any{"api_version": 1, "schema_version": 48, "required_schema_version": 48, "coordination_channel": nil}
		if channel != "" {
			meta["coordination_channel"] = map[string]any{"id": channel}
		}
		json.NewEncoder(w).Encode(meta)
	})
	mux.HandleFunc("POST /api/v1/conversations/send", func(w http.ResponseWriter, r *http.Request) {
		var payload map[string]any
		json.NewDecoder(r.Body).Decode(&payload)
		reached = append(reached, "send:"+payload["channel_id"].(string))
		w.Write([]byte(`{"duplicate":false,"post":{"id":"post-1"},"msg_id":"msg-1","state":"sent"}`))
	})
	mux.HandleFunc("GET /api/v1/conversations/reads", func(w http.ResponseWriter, r *http.Request) {
		reached = append(reached, "read:"+r.URL.Query().Get("channel_id"))
		w.Write([]byte(`{"posts":[],"caught_up":false,"incomplete_reason":null}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENT_ID", "seat-a")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	return server, &reached
}

func TestChatCoordinationResolvesTheServerChannel(t *testing.T) {
	_, reached := coordinationBoard(t, "tg3thqx96t87myboasiemfipry")
	if _, stderr, err := runChatCommand(t, "chat", "read", "--coordination", "--json"); err != nil {
		t.Fatalf("read: %v %s", err, stderr)
	}
	if _, stderr, err := runChatCommand(t, "chat", "send", "--coordination", "--body", "claimed sr-1", "--retry-key", "k1", "--json"); err != nil {
		t.Fatalf("send: %v %s", err, stderr)
	}
	want := []string{"read:tg3thqx96t87myboasiemfipry", "send:tg3thqx96t87myboasiemfipry"}
	if strings.Join(*reached, ",") != strings.Join(want, ",") {
		t.Fatalf("coordination reached %v, want %v", *reached, want)
	}
}

func TestChatCoordinationRefusesWhenTheServerHasNone(t *testing.T) {
	_, reached := coordinationBoard(t, "")
	for _, args := range [][]string{
		{"chat", "read", "--coordination"},
		{"chat", "send", "--coordination", "--body", "hi"},
	} {
		_, _, err := runChatCommand(t, args...)
		if err == nil || !strings.Contains(err.Error(), "AGENTBOARD_COORDINATION_CHANNEL_ID") {
			t.Fatalf("%v: want a no-coordination-channel error, got %v", args, err)
		}
	}
	if len(*reached) != 0 {
		t.Fatalf("nothing may be sent or read without a channel: %v", *reached)
	}
}

func TestChatCoordinationIsExclusiveWithOtherDestinations(t *testing.T) {
	_, reached := coordinationBoard(t, "tg3thqx96t87myboasiemfipry")
	for _, args := range [][]string{
		{"chat", "read", "--coordination", "--channel", "c"},
		{"chat", "read", "--coordination", "--inbox"},
		{"chat", "send", "--coordination", "--to", "seat-b", "--body", "x"},
		{"chat", "send", "--coordination", "--channel", "c", "--body", "x"},
	} {
		if _, _, err := runChatCommand(t, args...); err == nil {
			t.Fatalf("%v must be rejected", args)
		}
	}
	if len(*reached) != 0 {
		t.Fatalf("rejected flags must not reach the API: %v", *reached)
	}
}
