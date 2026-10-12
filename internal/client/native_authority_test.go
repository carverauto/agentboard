package client

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/config"
)

type authorityRoundTrip func(*http.Request) (*http.Response, error)

func (f authorityRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func authorityResponse(code int, body string) *http.Response {
	return &http.Response{StatusCode: code, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}
}

func TestNativeAuthorityProtectedTransportWithoutRetryOrRedirect(t *testing.T) {
	const token = "fixture-host-capability-not-live-0123456789"
	for _, status := range []int{200, 302, 401, 429, 500} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			c, err := NewRuntime(config.Config{URL: "https://board.example", Actor: config.Actor{ID: "worker-native", Model: "fixture", Harness: "codex"}}, token)
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			calls := 0
			c.http.Transport = authorityRoundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Method != "GET" || r.URL.String() != "https://board.example/api/v1/hosts/fixture-host/workers/worker-native/native-authority" || r.Header.Get("Authorization") != "Bearer "+token || r.Header.Get("X-Agentboard-Worker-Protocol") != "1" || r.Header.Get("X-Agentboard-Captain-Token") != "" {
					t.Fatal("host authority route/scope changed")
				}
				response := authorityResponse(status, `{"reflection":"`+token+`"}`)
				response.Header.Set("Location", "https://other.example/secret")
				response.Header.Set("Retry-After", "0")
				return response, nil
			})
			result, err := c.JSONOnce(context.Background(), http.MethodGet, "hosts/fixture-host/workers/worker-native/native-authority", nil, nil)
			if (status == 200) != (err == nil) || calls != 1 {
				t.Fatalf("retried/redirected authority request: %d calls, %v", calls, err)
			}
			if strings.Contains(string(result), token) || (err != nil && strings.Contains(err.Error(), token)) {
				t.Fatal("host capability reflected")
			}
		})
	}
}
func TestNativeAuthorityCaptainClosedOperationsAndNoReplay(t *testing.T) {
	const token = "fixture-captain-capability-not-live-0123456789"
	for _, operation := range []string{"native-approval", "native-retire"} {
		t.Run(operation, func(t *testing.T) {
			c, err := NewCaptain(config.Config{URL: "https://board.example"}, token)
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			calls := 0
			c.http.Transport = authorityRoundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Header.Get("X-Agentboard-Captain-Token") != token || r.Header.Get("Authorization") != "" || r.Header.Get("X-Agentboard-Worker-Protocol") != "1" || r.Method != "POST" || r.URL.Path != "/api/v1/workers/worker-native/"+operation {
					t.Fatal("captain request changed scope")
				}
				response := authorityResponse(429, `{"error":{"code":"rate_limited","message":"`+token+`"}}`)
				response.Header.Set("Retry-After", "0")
				return response, nil
			})
			_, err = c.WorkerControl(context.Background(), operation, "worker-native", map[string]any{"expected_authority_revision": 0, "idempotency_key": "fixture-key"})
			if err == nil || calls != 1 || strings.Contains(err.Error(), token) {
				t.Fatal("captain mutation replayed or leaked")
			}
			if _, err = c.WorkerControl(context.Background(), "bind", "worker-native", nil); err == nil || calls != 1 {
				t.Fatal("broadened captain operation set")
			}
			runtime, err := NewRuntime(config.Config{URL: "https://board.example"}, token)
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()
			if _, err = runtime.WorkerControl(context.Background(), operation, "worker-native", nil); err == nil {
				t.Fatal("host client acquired captain mutation")
			}
		})
	}
}
