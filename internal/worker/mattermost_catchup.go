package worker

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"sort"
	"strconv"
	"time"
)

// mmInbox owns one member's metadata ledger. Callers serialize it through the
// existing protected-file lock; the live reader only buffers wire events.
type mmInbox struct {
	transport  *mmTransport
	ledger     *mmLedger
	path       string
	bridges    map[string]bool
	channels   map[string]bool
	teams      map[string]bool
	directs    bool
	pageSize   int
	maxPages   int
	authorized map[string]bool
}

func (i *mmInbox) save() error { return WriteProtected(i.path, i.ledger) }

func (i *mmInbox) discover(ctx context.Context) ([]string, error) {
	var channels []struct {
		ID      string `json:"id"`
		Team    string `json:"team_id"`
		Type    string `json:"type"`
		Deleted int64  `json:"delete_at"`
	}
	if err := i.transport.get(ctx, "users/me/channels", nil, &channels); err != nil {
		return nil, err
	}
	if len(channels) > 1000 {
		return nil, errors.New("Mattermost channel discovery capacity reached; catch-up incomplete")
	}
	authorized := map[string]bool{}
	for _, c := range channels {
		if c.ID == "" || c.Deleted != 0 {
			continue
		}
		if i.channels[c.ID] || i.teams[c.Team] || (i.directs && (c.Type == "D" || c.Type == "G")) {
			authorized[c.ID] = true
			if i.ledger.Channels[c.ID] == nil {
				i.ledger.Channels[c.ID] = &mmCoverage{Reasons: []string{"history_retention_unverified"}}
			}
		}
	}
	for id, coverage := range i.ledger.Channels {
		if !authorized[id] {
			coverage.ScanComplete = false
			coverage.Reasons = addMMReason(coverage.Reasons, "membership_unavailable")
			for _, ref := range i.ledger.References {
				if ref.Channel == id {
					ref.Unavailable = "membership_unavailable"
				}
			}
		}
	}
	i.authorized = authorized
	ids := make([]string, 0, len(authorized))
	for id := range authorized {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids, i.save()
}

type mmPostPage struct {
	Order []string          `json:"order"`
	Posts map[string]mmPost `json:"posts"`
}

// Repeating complete offset scans creates page overlap without relying on a
// timestamp or a create_at-only before cursor that can skip equal-time posts.
// Stable visible history is reported separately from a provably closed gap.
// Member REST cannot prove deleted/retained-away history, so it never clears
// history_retention_unverified or an outage's deletion-history warning.
func (i *mmInbox) reconcileChannel(ctx context.Context, channel string) error {
	c := i.ledger.Channels[channel]
	c.ScanComplete = false
	lastFingerprint := ""
	for pass := 0; pass < 3; pass++ {
		seen := map[string]string{}
		complete := false
		for page := 0; page < i.maxPages; page++ {
			c.Pass, c.NextPage = pass, page
			if err := i.save(); err != nil {
				return err
			}
			var response mmPostPage
			query := url.Values{"page": {strconv.Itoa(page)}, "per_page": {strconv.Itoa(i.pageSize)}}
			if err := i.transport.get(ctx, "channels/"+url.PathEscape(channel)+"/posts", query, &response); err != nil {
				c.Reasons = addMMReason(c.Reasons, "history_request_unavailable")
				return err
			}
			if len(response.Order) > i.pageSize || response.Posts == nil {
				return errors.New("invalid Mattermost history page")
			}
			pageIDs := map[string]bool{}
			for _, id := range response.Order {
				post, exists := response.Posts[id]
				if !exists || post.ID != id || post.Channel != channel || pageIDs[id] {
					return errors.New("invalid Mattermost history page membership")
				}
				pageIDs[id] = true
				version, _ := post.version()
				seen[id] = version
				if err := i.ledger.observe(post, i.bridges); err != nil {
					return err
				}
			}
			c.NextPage = page + 1
			if err := i.save(); err != nil {
				return err
			}
			if len(response.Order) < i.pageSize {
				complete = true
				break
			}
		}
		if !complete {
			c.Reasons = addMMReason(c.Reasons, "page_budget_exhausted")
			return errors.New("Mattermost history page budget exhausted; unfinished job retained")
		}
		ids := make([]string, 0, len(seen))
		for id := range seen {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		hash := sha256.New()
		for _, id := range ids {
			hash.Write([]byte(id + ":" + seen[id] + "\n"))
		}
		fingerprint := hex.EncodeToString(hash.Sum(nil))
		if fingerprint == lastFingerprint {
			c.ScanComplete, c.ScannedAt = true, time.Now().UnixMilli()
			c.NextPage = 0
			return i.reconcileMissing(ctx, channel, seen)
		}
		lastFingerprint = fingerprint
	}
	c.Reasons = addMMReason(c.Reasons, "history_changed_during_pagination")
	return errors.New("Mattermost visible history changed during pagination; catch-up incomplete")
}

func (i *mmInbox) reconcileMissing(ctx context.Context, channel string, visible map[string]string) error {
	checked := map[string]bool{}
	for _, ref := range i.ledger.References {
		if ref.Channel != channel || visible[ref.Post] != "" || checked[ref.Post] || ref.Deleted > 0 {
			continue
		}
		checked[ref.Post] = true
		var post mmPost
		err := i.transport.get(ctx, "posts/"+url.PathEscape(ref.Post), nil, &post)
		var httpErr *mmHTTPError
		if errors.As(err, &httpErr) && (httpErr.Status == 403 || httpErr.Status == 404) {
			for _, version := range i.ledger.References {
				if version.Post == ref.Post {
					version.Unavailable = "deleted_retained_or_inaccessible"
				}
			}
			i.ledger.Channels[channel].Reasons = addMMReason(i.ledger.Channels[channel].Reasons, "source_unavailable")
			continue
		}
		if err != nil {
			return err
		}
		if post.ID != ref.Post || post.Channel != channel {
			return errors.New("Mattermost source identity changed during reconciliation")
		}
		if err := i.ledger.observe(post, i.bridges); err != nil {
			return err
		}
	}
	return i.save()
}

// live returns true when an authoritative membership/history reread is needed.
// Receiving source text is not permission to execute it or acknowledge it.
func (i *mmInbox) live(event mmLiveEvent) (bool, error) {
	switch event.Event {
	case "posted", "post_edited", "post_deleted":
		var encoded string
		var post mmPost
		if json.Unmarshal(event.Data["post"], &encoded) != nil || json.Unmarshal([]byte(encoded), &post) != nil {
			return false, errors.New("invalid Mattermost live post")
		}
		if event.Event == "post_deleted" && post.Deleted == 0 {
			return false, errors.New("Mattermost deletion version missing; source unavailable")
		}
		if !i.authorized[post.Channel] {
			return true, nil
		}
		if err := i.ledger.observe(post, i.bridges); err != nil {
			return false, err
		}
		return false, i.save()
	case "direct_added", "group_added", "channel_created", "user_added", "user_removed", "channel_deleted", "leave_team", "added_to_team":
		return true, nil
	default:
		return false, nil
	}
}
