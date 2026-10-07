package worker

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
)

// mmPost is the authoritative Mattermost wire representation. Bodies are never
// serialized into the inbox ledger; only exact-version references are retained.
type mmPost struct {
	ID      string         `json:"id"`
	Channel string         `json:"channel_id"`
	Root    string         `json:"root_id"`
	User    string         `json:"user_id"`
	Created int64          `json:"create_at"`
	Updated int64          `json:"update_at"`
	Edited  int64          `json:"edit_at"`
	Deleted int64          `json:"delete_at"`
	Message string         `json:"message"`
	Type    string         `json:"type"`
	Props   map[string]any `json:"props"`
	FileIDs []string       `json:"file_ids"`
}

// The content hash also distinguishes edits with equal millisecond timestamps.
// WebSocket sequence numbers are deliberately absent from source identity.
func (p mmPost) version() (string, string) {
	bytes, _ := json.Marshal(p)
	hash := sha256.Sum256(bytes)
	digest := hex.EncodeToString(hash[:])
	return fmt.Sprintf("%d:%d:%d:%s", p.Updated, p.Edited, p.Deleted, digest), digest
}

type mmReference struct {
	Post        string `json:"post_id"`
	Version     string `json:"update_version"`
	Hash        string `json:"content_hash"`
	Channel     string `json:"channel_id"`
	Root        string `json:"root_id,omitempty"`
	User        string `json:"user_id"`
	Created     int64  `json:"create_at"`
	Updated     int64  `json:"update_at"`
	Deleted     int64  `json:"delete_at,omitempty"`
	Suppression string `json:"suppression,omitempty"`
	Handled     bool   `json:"handled"`
	Unavailable string `json:"source_unavailable,omitempty"`
}

type mmCoverage struct {
	NextPage     int      `json:"next_page"`
	Pass         int      `json:"pass"`
	ScanComplete bool     `json:"visible_history_reconciled"`
	ScannedAt    int64    `json:"scanned_at,omitempty"`
	Reasons      []string `json:"incomplete_reasons"`
}

type mmLedger struct {
	Version    int                     `json:"version"`
	Server     string                  `json:"server_id"`
	Agent      string                  `json:"agent_id"`
	User       string                  `json:"user_id"`
	Start      int64                   `json:"history_start_at"`
	Connected  bool                    `json:"connected"`
	Reasons    []string                `json:"incomplete_reasons"`
	References map[string]*mmReference `json:"references"`
	Channels   map[string]*mmCoverage  `json:"channels"`
}

func loadMMLedger(path, server, agent, user string, start int64) (*mmLedger, error) {
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return &mmLedger{Version: 1, Server: server, Agent: agent, User: user, Start: start,
			References: map[string]*mmReference{}, Channels: map[string]*mmCoverage{}}, nil
	}
	data, err := ReadProtected(path, 32<<20)
	if err != nil {
		return nil, err
	}
	var l mmLedger
	if json.Unmarshal(data, &l) != nil || l.Version != 1 || l.Server != server || l.Agent != agent || l.User != user || l.Start != start || l.References == nil || l.Channels == nil {
		return nil, errors.New("Mattermost ledger identity or history start mismatch; explicit enrollment required")
	}
	for key, ref := range l.References {
		if ref == nil || ref.Post == "" || ref.Channel == "" || ref.User == "" || len(ref.Hash) != 64 || key != ref.Post+":"+ref.Version {
			return nil, errors.New("invalid Mattermost exact-version ledger; recovery disabled")
		}
	}
	for id, coverage := range l.Channels {
		if id == "" || coverage == nil || coverage.NextPage < 0 || coverage.Pass < 0 {
			return nil, errors.New("invalid Mattermost recovery job; recovery disabled")
		}
	}
	return &l, nil
}

func addMMReason(reasons []string, reason string) []string {
	for _, existing := range reasons {
		if existing == reason {
			return reasons
		}
	}
	return append(reasons, reason)
}

func (l *mmLedger) observe(p mmPost, bridges map[string]bool) error {
	if p.ID == "" || p.Channel == "" || p.User == "" || p.Created < 0 || p.Updated < 0 || p.Edited < 0 || p.Deleted < 0 {
		return errors.New("invalid Mattermost post reference")
	}
	if max(p.Created, p.Updated, p.Edited, p.Deleted) < l.Start {
		return nil
	}
	version, digest := p.version()
	key := p.ID + ":" + version
	if l.References[key] != nil {
		return nil
	}
	if len(l.References) >= 50000 {
		return errors.New("Mattermost exact-version ledger capacity reached; pending references retained")
	}
	r := &mmReference{Post: p.ID, Version: version, Hash: digest, Channel: p.Channel, Root: p.Root,
		User: p.User, Created: p.Created, Updated: max(p.Updated, p.Edited), Deleted: p.Deleted}
	if p.User == l.User {
		r.Suppression = "own_send"
	} else if bridges[p.User] {
		r.Suppression = "lifecycle_bridge"
	}
	if p.Deleted > 0 {
		r.Unavailable = "deleted"
		for _, previous := range l.References {
			if previous.Post == p.ID {
				previous.Unavailable = "deleted"
			}
		}
	}
	// A delayed pre-deletion page must not resurrect an already observed tombstone.
	for _, previous := range l.References {
		if previous.Post == p.ID && previous.Deleted > 0 {
			r.Unavailable = "deleted"
			break
		}
	}
	l.References[key] = r
	return nil
}

func (l *mmLedger) pendingKeys() []string {
	keys := []string{}
	for key, r := range l.References {
		if !r.Handled && r.Suppression == "" {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	return keys
}

func (l *mmLedger) incomplete() bool {
	if !l.Connected || len(l.Reasons) != 0 {
		return true
	}
	for _, c := range l.Channels {
		if !c.ScanComplete || len(c.Reasons) != 0 {
			return true
		}
	}
	return false
}
