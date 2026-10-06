package client_test

import (
	"context"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
)

func api(t *testing.T, address string) *client.Client {
	t.Helper()
	c, err := client.New(config.Config{URL: address, Actor: config.Actor{ID: "worker-a", Model: "model-1", Harness: "codex"}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c
}

func TestRateLimitedWriteWaitsAndReplaysSameBody(t *testing.T) {
	for _, kind := range []string{"seconds", "http-date", "malformed"} {
		t.Run(kind, func(t *testing.T) {
			var calls atomic.Int32
			var floor time.Time
			issues := make(chan string, 10)
			arrival := make(chan time.Time, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				if r.Method != "POST" || r.URL.Path != "/api/v1/tasks" || string(body) != `{"title":"work"}` {
					issues <- "request body, method, or route changed"
				}
				if r.Header.Get("X-Agentboard-Agent") != "worker-a" || r.Header.Get("X-Agentboard-Model") != "model-1" || r.Header.Get("X-Agentboard-Harness") != "codex" {
					issues <- "provenance missing"
				}
				if calls.Add(1) == 1 {
					now := time.Now()
					header := "1"
					floor = now.Add(time.Second)
					if kind == "http-date" {
						floor = now.Add(2 * time.Second).UTC().Truncate(time.Second)
						header = floor.Format(http.TimeFormat)
					}
					if kind == "malformed" {
						header = "not-a-delay"
					}
					w.Header().Set("Retry-After", header)
					w.WriteHeader(429)
					io.WriteString(w, `{"error":{"code":"rate_limited","message":"wait"}}`)
					return
				}
				arrival <- time.Now()
				io.WriteString(w, `{"task":{"id":"work"}}`)
			}))
			defer server.Close()
			result, err := api(t, server.URL).JSON(context.Background(), "POST", "tasks", nil, map[string]string{"title": "work"})
			if err != nil {
				t.Fatal(err)
			}
			if string(result) != `{"task":{"id":"work"}}` || calls.Load() != 2 {
				t.Fatalf("result %s calls %d", result, calls.Load())
			}
			if at := <-arrival; at.Before(floor) {
				t.Fatalf("retried %s before permitted time", floor.Sub(at))
			}
			select {
			case issue := <-issues:
				t.Fatal(issue)
			default:
			}
		})
	}
}

func TestRateLimitBudgetStopsFurtherRequests(t *testing.T) {
	for _, header := range []string{"0", "121", "999999999999999999999999999999"} {
		t.Run(header, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				calls.Add(1)
				w.Header().Set("Retry-After", header)
				w.WriteHeader(429)
			}))
			defer server.Close()
			_, err := api(t, server.URL).JSON(context.Background(), "POST", "tasks", nil, map[string]string{"title": "work"})
			var failure *client.Error
			if !errors.As(err, &failure) || failure.Code != "rate_limited" || failure.ExitCode() != 1 {
				t.Fatalf("unexpected error %v", err)
			}
			want := int32(1)
			if header == "0" {
				want = 4
			}
			if calls.Load() != want {
				t.Fatalf("calls %d, want %d", calls.Load(), want)
			}
		})
	}
}

func TestRetryCancellationDoesNotSendAnotherRequest(t *testing.T) {
	var calls atomic.Int32
	requested := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.Header().Set("Retry-After", "10")
		w.WriteHeader(429)
		requested <- struct{}{}
	}))
	defer server.Close()
	c := api(t, server.URL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan error, 1)
	go func() {
		_, err := c.JSON(ctx, "POST", "tasks", nil, map[string]string{"title": "work"})
		finished <- err
	}()
	select {
	case <-requested:
	case <-time.After(5 * time.Second):
		t.Fatal("no request")
	}
	cancel()
	select {
	case err := <-finished:
		if err == nil || calls.Load() != 1 {
			t.Fatalf("error %v calls %d", err, calls.Load())
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation did not finish promptly")
	}
}

func TestHTTPStatusMapsToExitCodeWithoutRetry(t *testing.T) {
	for status, exit := range map[int]int{400: 2, 422: 2, 404: 3, 409: 4, 503: 1} {
		var calls atomic.Int32
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			calls.Add(1)
			w.WriteHeader(status)
			io.WriteString(w, `{"error":{"code":"conflict","message":"request rejected"}}`)
		}))
		_, err := api(t, server.URL).JSON(context.Background(), "POST", "tasks", nil, map[string]string{"title": "work"})
		server.Close()
		var failure *client.Error
		if !errors.As(err, &failure) || failure.ExitCode() != exit || calls.Load() != 1 {
			t.Fatalf("status %d error %v calls %d", status, err, calls.Load())
		}
	}
}

func TestLostWriteResponseIsNotReplayed(t *testing.T) {
	var committed atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		committed.Add(1)
		connection, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			connection.Close()
		}
	}))
	defer server.Close()
	_, err := api(t, server.URL).JSON(context.Background(), "POST", "tasks", nil, map[string]string{"title": "work"})
	if err == nil || !strings.Contains(err.Error(), "write outcome may be unknown") || committed.Load() != 1 {
		t.Fatalf("error %v committed %d", err, committed.Load())
	}
}

func TestHTTPSRejectsUntrustedCertificateAndAcceptsConfiguredCA(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		io.WriteString(w, `{"api_version":1}`)
	}))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	defer server.Close()
	_, err := api(t, server.URL).JSON(context.Background(), "GET", "meta", nil, nil)
	if err == nil || calls.Load() != 0 {
		t.Fatalf("untrusted HTTPS accepted: error %v calls %d", err, calls.Load())
	}
	ca := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600); err != nil {
		t.Fatal(err)
	}
	c, err := client.New(config.Config{URL: server.URL, CAFile: ca})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err := c.JSON(context.Background(), "GET", "meta", nil, nil); err != nil || calls.Load() != 1 {
		t.Fatalf("trusted HTTPS failed: error %v calls %d", err, calls.Load())
	}
}

func TestRedirectDoesNotForwardCallerContext(t *testing.T) {
	var forwarded atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { forwarded.Add(1); io.WriteString(w, `{}`) }))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 307) }))
	defer server.Close()
	_, err := api(t, server.URL).JSON(context.Background(), "POST", "tasks", nil, map[string]string{"title": "work"})
	if err == nil || forwarded.Load() != 0 {
		t.Fatalf("redirect followed: error %v forwarded %d", err, forwarded.Load())
	}
}
