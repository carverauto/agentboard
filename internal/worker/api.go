package worker

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
)

type Batch struct {
	ID         string   `json:"batch_id"`
	Attempt    string   `json:"attempt_id"`
	Agent      string   `json:"worker_id"`
	Epoch      int64    `json:"binding_epoch"`
	Generation int64    `json:"dispatch_generation"`
	Hash       string   `json:"payload_hash"`
	Payload    string   `json:"payload"`
	IDs        []string `json:"delivery_ids"`
	Lease      string   `json:"lease_expires_at"`
	More       bool     `json:"more"`
}

func (b Batch) Validate(binding Binding) error {
	h := sha256.Sum256([]byte(b.Payload))
	if b.ID == "" || b.Attempt == "" || b.Agent != binding.Agent || b.Epoch != binding.Epoch || b.Generation < 1 || len(b.Payload) > MaxFrameBytes || len(b.IDs) == 0 || len(b.IDs) > 20 || hex.EncodeToString(h[:]) != b.Hash || !json.Valid([]byte(b.Payload)) {
		return errors.New("invalid frozen worker batch")
	}
	seen := map[string]bool{}
	for _, id := range b.IDs {
		if id == "" || seen[id] {
			return errors.New("invalid frozen delivery membership")
		}
		seen[id] = true
	}
	return nil
}

func (b Batch) Fences() map[string]any {
	return map[string]any{"binding_epoch": b.Epoch, "dispatch_generation": b.Generation, "payload_hash": b.Hash}
}

type API struct {
	client *client.Client
	agent  string
}

func OpenAPI(cfg Config, b Binding, receipt bool) (*API, error) {
	accessFile, err := cfg.accessServiceTokenFile()
	if err != nil {
		return nil, err
	}
	path := b.TokenFile
	if receipt {
		path += ".receipt"
	}
	data, err := ReadProtected(path, 4096)
	if err != nil {
		return nil, err
	}
	token := strings.TrimSpace(string(data))
	c, err := client.NewRuntime(config.Config{
		URL: cfg.URL, CAFile: cfg.CAFile, AccessServiceTokenFile: accessFile,
		Actor: config.Actor{ID: b.Agent, Model: b.Model, Harness: b.Harness},
	}, token)
	if err != nil {
		return nil, err
	}
	return &API{c, b.Agent}, nil
}

func (a *API) Close() { a.client.Close() }

func (a *API) Call(ctx context.Context, method, action string, query url.Values, body any) (json.RawMessage, error) {
	return a.call(ctx, method, "workers/"+url.PathEscape(a.agent)+"/"+action, query, body)
}

func (a *API) wakePage(ctx context.Context, b Binding, query url.Values) (json.RawMessage, error) {
	return a.call(ctx, http.MethodGet, "hosts/"+url.PathEscape(b.Host)+"/wake-intents/"+url.PathEscape(a.agent), query, nil)
}

func (a *API) call(ctx context.Context, method, path string, query url.Values, body any) (json.RawMessage, error) {
	raw, err := a.client.JSON(ctx, method, path, query, body)
	if err != nil {
		var e *client.Error
		if errors.As(err, &e) {
			return nil, &client.Error{Code: e.Code, Status: e.Status, RetryAfter: e.RetryAfter, Message: fmt.Sprintf("worker API %s (HTTP %d); inspect state before retrying writes", e.Code, e.Status)}
		}
		return nil, errors.New("worker API request failed")
	}
	var version struct {
		Protocol int `json:"protocol_revision"`
	}
	if json.Unmarshal(raw, &version) != nil || version.Protocol != Protocol {
		return nil, errors.New("worker API protocol unavailable or incompatible")
	}
	return raw, nil
}

// CheckIn exhausts each authoritative page without consuming deliveries.
func (a *API) CheckIn(ctx context.Context) (map[string]any, error) {
	result := map[string]any{"protocol_revision": Protocol}
	state, err := a.Call(ctx, http.MethodGet, "state", nil, nil)
	if err != nil {
		return nil, err
	}
	result["state"] = json.RawMessage(state)
	totalBytes := len(state)
	var capabilities struct {
		Worker struct {
			MattermostInbox bool `json:"mattermost_inbox_supported"`
		} `json:"worker"`
	}
	if json.Unmarshal(state, &capabilities) != nil {
		return nil, errors.New("invalid worker state")
	}
	actions := []string{"responsibilities", "obligations", "pending"}
	if capabilities.Worker.MattermostInbox {
		actions = append(actions, "mattermost_inbox")
	}
	for _, action := range actions {
		pages := []json.RawMessage{}
		cursor := ""
		seen := map[string]bool{}
		for {
			q := url.Values{"limit": {"100"}}
			if cursor != "" {
				q.Set("cursor", cursor)
			}
			raw, err := a.Call(ctx, http.MethodGet, action, q, nil)
			if err != nil {
				return nil, err
			}
			totalBytes += len(raw)
			if totalBytes > 8<<20 {
				return nil, errors.New("worker catch-up incomplete: output exceeds 8 MiB; use paginated API reads")
			}
			pages = append(pages, raw)
			var page struct {
				Cursor *string `json:"next_cursor"`
			}
			if json.Unmarshal(raw, &page) != nil {
				return nil, errors.New("invalid recovery page")
			}
			if page.Cursor == nil || *page.Cursor == "" {
				break
			}
			cursor = *page.Cursor
			if seen[cursor] || len(pages) >= 1000 {
				return nil, errors.New("worker catch-up incomplete: repeated cursor or page budget exhausted")
			}
			seen[cursor] = true
		}
		result[action] = pages
	}
	return result, nil
}
