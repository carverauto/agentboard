package worker

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

// InboxItem identifies one immutable Mattermost inbox version, not a channel or
// a cooperation delivery. Reads and acknowledgements always name both fields.
type InboxItem struct {
	ID      string `json:"id"`
	Version string `json:"version"`
}

func (item InboxItem) Validate() error {
	if len(item.ID) != 36 || item.ID[8] != '-' || item.ID[13] != '-' || item.ID[18] != '-' || item.ID[23] != '-' {
		return errors.New("exact Mattermost inbox UUID and lowercase SHA-256 version required")
	}
	id, err := hex.DecodeString(strings.ReplaceAll(item.ID, "-", ""))
	if err != nil || len(id) != 16 || len(item.Version) != 64 || item.Version != strings.ToLower(item.Version) {
		return errors.New("exact Mattermost inbox UUID and lowercase SHA-256 version required")
	}
	if _, err := hex.DecodeString(item.Version); err != nil {
		return errors.New("exact Mattermost inbox UUID and lowercase SHA-256 version required")
	}
	return nil
}

// MattermostRead returns the current source body only if the server can still
// verify the exact version and this worker's access. It never acknowledges.
func (a *API) MattermostRead(ctx context.Context, item InboxItem) (json.RawMessage, error) {
	if err := item.Validate(); err != nil {
		return nil, err
	}
	return a.Call(ctx, http.MethodPost, "mattermost_read", nil, item)
}

// MattermostAck explicitly handles exact inbox versions. The server makes the
// batch atomic and retains the first handling attribution on retries.
func (a *API) MattermostAck(ctx context.Context, items []InboxItem) (json.RawMessage, error) {
	if len(items) < 1 || len(items) > 50 {
		return nil, errors.New("Mattermost acknowledgement requires 1 to 50 exact inbox items")
	}
	seen := make(map[string]bool, len(items))
	for _, item := range items {
		if err := item.Validate(); err != nil {
			return nil, err
		}
		id := strings.ToLower(item.ID)
		if seen[id] {
			return nil, errors.New("Mattermost acknowledgement requires unique inbox items")
		}
		seen[id] = true
	}
	return a.Call(ctx, http.MethodPost, "mattermost_ack", nil, map[string]any{"items": items})
}
