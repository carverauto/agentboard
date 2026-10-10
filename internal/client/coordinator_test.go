package client_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
)

func TestCoordinatorProtocolHeaderIsRequestLocal(t *testing.T) {
	const bearer = "fixture-ordinary-runner-bearer-0123456789"
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		want := ""
		if strings.HasPrefix(r.URL.Path, "/api/v1/coordinator/") {
			want = "1"
		}
		if r.Header.Get("X-Agentboard-Coordinator-Protocol") != want || r.Header.Get("Authorization") != "Bearer "+bearer || r.Header.Get("X-Agentboard-Captain-Token") != "" || r.Header.Get("X-Agentboard-Worker-Protocol") != "" {
			t.Error("protocol/auth header crossed request boundary")
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"protocol_revision":1}`)
	}))
	defer server.Close()
	c, err := client.New(config.Config{URL: server.URL, Token: bearer})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var wait sync.WaitGroup
	for _, operation := range []struct{ method, path string }{
		{http.MethodGet, "coordinator/tick"},
		{http.MethodGet, "coordinator/decisions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},
		{http.MethodPost, "coordinator/ack"},
		{http.MethodPost, "coordinator/heartbeat"},
		{http.MethodGet, "meta"},
		{http.MethodGet, "tasks"},
	} {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if strings.HasPrefix(operation.path, "coordinator/") {
				_, err := c.CoordinatorJSON(context.Background(), operation.method, operation.path, nil, nil)
				if err != nil {
					t.Error(err)
				}
			} else if _, err := c.JSON(context.Background(), operation.method, operation.path, nil, nil); err != nil {
				t.Error(err)
			}
		}()
	}
	wait.Wait()
	if calls.Load() != 6 {
		t.Fatalf("requests %d", calls.Load())
	}
}

func TestCoordinatorTransportRejectsWrongCapabilitiesAndOperations(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1) }))
	defer server.Close()
	const token = "fixture-synthetic-capability-0123456789"
	cfg := config.Config{URL: server.URL}
	for name, constructor := range map[string]func() (*client.Client, error){
		"absent":  func() (*client.Client, error) { return client.New(cfg) },
		"captain": func() (*client.Client, error) { return client.NewCaptain(cfg, token) },
		"worker":  func() (*client.Client, error) { return client.NewRuntime(cfg, token) },
	} {
		t.Run(name, func(t *testing.T) {
			c, err := constructor()
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			if _, err := c.CoordinatorJSON(context.Background(), http.MethodGet, "coordinator/tick", nil, nil); err == nil {
				t.Fatal("unsupported capability reached coordinator transport")
			}
		})
	}
	cfg.Token = token
	c, err := client.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for _, operation := range []struct{ method, path string }{
		{http.MethodGet, "meta"}, {http.MethodGet, "tasks"}, {http.MethodPost, "coordinator/tick"},
		{http.MethodGet, "coordinator/ack"}, {http.MethodGet, "coordinator/heartbeat"},
		{http.MethodPost, "coordinator/decisions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},
		{http.MethodGet, "coordinator/decisions/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"},
		{http.MethodGet, "coordinator/decisions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/answer"},
		{http.MethodGet, "coordinator/decisions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n"},
		{http.MethodPost, "coordinator/ack/../answer"}, {http.MethodGet, "coordinator/decisions"},
	} {
		if _, err := c.CoordinatorJSON(context.Background(), operation.method, operation.path, nil, nil); err == nil {
			t.Errorf("accepted operation %s %s", operation.method, operation.path)
		}
	}
	if calls.Load() != 0 {
		t.Fatalf("rejected input made %d requests", calls.Load())
	}
}
