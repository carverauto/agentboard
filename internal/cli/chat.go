package cli

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

// Headless Mattermost send/read with the worker's own token.
//
// The server maps stable agent IDs to Mattermost users and verifies
// membership, but it never proxies message bodies: sends and reads go
// straight to the Mattermost REST API with a worker-held token. The token
// lives in a Secret-mounted file named by
// AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE and never appears in flags,
// output, or logs; only the credential reference is stored server-side.

const (
	mmRetryKeyProp = "agentboard_retry_key"
	mmAgentProp    = "agentboard_agent"
	mmMaxBody      = 1 << 20
)

type mmTarget struct {
	base   *url.URL
	token  string
	client *http.Client
}

func mmTransport(caFile string) (*http.Transport, error) {
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, errors.New("cannot read AGENTBOARD_CA_FILE")
		}
		roots, err := x509.SystemCertPool()
		if err != nil {
			roots = x509.NewCertPool()
		}
		if !roots.AppendCertsFromPEM(pem) {
			return nil, errors.New("AGENTBOARD_CA_FILE contains no valid CA certificate")
		}
		tlsConfig.RootCAs = roots
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = tlsConfig
	transport.DialContext = (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	transport.TLSHandshakeTimeout = 10 * time.Second
	transport.ResponseHeaderTimeout = 30 * time.Second
	return transport, nil
}

func mmConnect(caFile string) (*mmTarget, error) {
	rawBase := strings.TrimSpace(os.Getenv("AGENTBOARD_MATTERMOST_BASE_URL"))
	if rawBase == "" {
		return nil, errors.New("AGENTBOARD_MATTERMOST_BASE_URL is required for chat send/read")
	}
	base, err := url.Parse(rawBase)
	if err != nil || base.Hostname() == "" || base.User != nil {
		return nil, errors.New("AGENTBOARD_MATTERMOST_BASE_URL must be a base URL without credentials")
	}
	loopback := base.Hostname() == "localhost"
	if ip := net.ParseIP(base.Hostname()); ip != nil {
		loopback = ip.IsLoopback()
	}
	if base.Scheme != "https" && !(base.Scheme == "http" && loopback) {
		return nil, errors.New("Mattermost connections require HTTPS; HTTP is allowed only on loopback")
	}
	path := strings.TrimSpace(os.Getenv("AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE"))
	if path == "" {
		return nil, errors.New("AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE is required for chat send/read")
	}
	secret, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("cannot read worker token file")
	}
	token := strings.TrimSpace(string(secret))
	if token == "" || strings.ContainsAny(token, "\r\n\t ") {
		return nil, errors.New("worker token file is empty or malformed")
	}
	transport, err := mmTransport(caFile)
	if err != nil {
		return nil, err
	}
	return &mmTarget{base: base, token: token, client: &http.Client{Transport: transport, Timeout: 60 * time.Second}}, nil
}

func (m *mmTarget) call(method, path string, query url.Values, payload any) (int, json.RawMessage, error) {
	u := *m.base
	u.Path = strings.TrimRight(m.base.Path, "/") + "/api/v4/" + strings.TrimLeft(path, "/")
	u.RawQuery = query.Encode()
	var body []byte
	var err error
	if payload != nil {
		body, err = json.Marshal(payload)
		if err != nil {
			return 0, nil, errors.New("cannot encode Mattermost request")
		}
	}
	req, err := http.NewRequest(method, u.String(), bytes.NewReader(body))
	if err != nil {
		return 0, nil, errors.New("cannot construct Mattermost request")
	}
	req.Header.Set("Authorization", "Bearer "+m.token)
	req.Header.Set("User-Agent", "agentboard-cli/0.1")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return 0, nil, errors.New("Mattermost connection failed; check reachability and HTTPS trust")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, mmMaxBody+1))
	if err != nil || len(data) > mmMaxBody {
		return 0, nil, errors.New("Mattermost response could not be read")
	}
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return resp.StatusCode, nil, errors.New("Mattermost rejected the worker token; rotate it out of band")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return resp.StatusCode, nil, fmt.Errorf("Mattermost request failed with status %d", resp.StatusCode)
	}
	if !json.Valid(data) {
		return 0, nil, errors.New("Mattermost returned invalid JSON")
	}
	return resp.StatusCode, json.RawMessage(data), nil
}

type mmPost struct {
	ID        string         `json:"id"`
	ChannelID string         `json:"channel_id"`
	UserID    string         `json:"user_id"`
	Message   string         `json:"message"`
	RootID    string         `json:"root_id"`
	CreateAt  int64          `json:"create_at"`
	UpdateAt  int64          `json:"update_at"`
	Props     map[string]any `json:"props"`
}

func (m *mmTarget) me() (string, error) {
	_, raw, err := m.call(http.MethodGet, "users/me", nil, nil)
	if err != nil {
		return "", err
	}
	var user struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(raw, &user); err != nil || user.ID == "" {
		return "", errors.New("Mattermost user lookup failed")
	}
	return user.ID, nil
}

func (m *mmTarget) channelPosts(channelID string, limit int) ([]string, map[string]mmPost, error) {
	return m.channelPostsPage(channelID, 0, limit)
}

func (m *mmTarget) channelPostsPage(channelID string, page, perPage int) ([]string, map[string]mmPost, error) {
	q := url.Values{}
	q.Set("page", fmt.Sprint(page))
	q.Set("per_page", fmt.Sprint(perPage))
	_, raw, err := m.call(http.MethodGet, "channels/"+channelID+"/posts", q, nil)
	if err != nil {
		return nil, nil, err
	}
	var envelope struct {
		Order []string          `json:"order"`
		Posts map[string]mmPost `json:"posts"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, nil, errors.New("Mattermost posts response could not be decoded")
	}
	return envelope.Order, envelope.Posts, nil
}

func (c *commands) chat() *cobra.Command {
	group := &cobra.Command{Use: "chat", Short: "Headless Mattermost send/read with the worker's own token"}
	group.AddCommand(c.chatIdentity(), c.chatSend(), c.chatRead(), c.chatReport())
	return group
}

func (c *commands) chatIdentity() *cobra.Command {
	agent := ""
	cmd := &cobra.Command{Use: "identity", Short: "Resolve the enrolled Mattermost identity for an agent", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&agent, "agent", "", "Agent ID to resolve (defaults to --agent)")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if agent == "" {
			agent = c.cfg.Actor.ID
		}
		if agent == "" {
			return errors.New("--agent or AGENT_ID is required")
		}
		return c.request(cmd, http.MethodGet, "conversations/identities/"+agent, nil, nil)
	}
	return cmd
}

func (c *commands) chatSend() *cobra.Command {
	channel, dm, body, rootID, retryKey := "", "", "", "", ""
	noCoverage := false
	cmd := &cobra.Command{Use: "send", Short: "Post to a channel, thread, or DM as the worker identity", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&channel, "channel", "", "Channel ID to post to (or resolved from --dm)")
	cmd.Flags().StringVar(&dm, "dm", "", "Mattermost user ID to open/resolve a direct channel with")
	cmd.Flags().StringVar(&body, "body", "", "Message text (required)")
	cmd.Flags().StringVar(&rootID, "root-id", "", "Root post ID to reply in a thread")
	cmd.Flags().StringVar(&retryKey, "retry-key", "", "Client idempotency key; a matching post from the last 5 pages (300 posts) is adopted, never duplicated")
	cmd.Flags().BoolVar(&noCoverage, "no-coverage", false, "Skip reporting the send as a coverage receipt")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		if body == "" || (channel == "" && dm == "") {
			return errors.New("--body and --channel or --dm are required")
		}
		mm, err := mmConnect(c.cfg.CAFile)
		if err != nil {
			return err
		}
		self, err := mm.me()
		if err != nil {
			return err
		}
		if dm != "" {
			_, raw, err := mm.call(http.MethodPost, "channels/direct", nil, []string{self, dm})
			if err != nil {
				return err
			}
			var resolved struct {
				ID string `json:"id"`
			}
			if err := json.Unmarshal(raw, &resolved); err != nil || resolved.ID == "" {
				return errors.New("Mattermost direct channel could not be resolved")
			}
			channel = resolved.ID
		}
		props := map[string]any{mmAgentProp: c.cfg.Actor.ID}
		if retryKey != "" {
			props[mmRetryKeyProp] = retryKey
			dupe, err := mm.findRetryKey(channel, retryKey, c.cfg.Actor.ID)
			if err != nil {
				return err
			}
			if dupe != nil {
				return c.chatEmit(cmd, map[string]any{"duplicate": true, "post": dupe}, channel, dupe.ID, noCoverage)
			}
		}
		payload := map[string]any{"channel_id": channel, "message": body, "props": props}
		if rootID != "" {
			payload["root_id"] = rootID
		}
		_, raw, err := mm.call(http.MethodPost, "posts", nil, payload)
		if err != nil {
			return err
		}
		var post mmPost
		if err := json.Unmarshal(raw, &post); err != nil || post.ID == "" {
			return errors.New("Mattermost post was not acknowledged with an ID")
		}
		return c.chatEmit(cmd, map[string]any{"duplicate": false, "post": post}, channel, post.ID, noCoverage)
	}
	return cmd
}

func (m *mmTarget) findRetryKey(channelID, retryKey, agentID string) (*mmPost, error) {
	for page := 0; page < 5; page++ {
		order, posts, err := m.channelPostsPage(channelID, page, 60)
		if err != nil {
			return nil, err
		}
		for _, id := range order {
			if post, ok := posts[id]; ok && post.ID != "" {
				if value, _ := post.Props[mmRetryKeyProp].(string); value == retryKey {
					if author, _ := post.Props[mmAgentProp].(string); author == agentID {
						dupe := post
						return &dupe, nil
					}
				}
			}
		}
		if len(order) < 60 {
			return nil, nil
		}
	}
	return nil, nil
}

func (c *commands) chatEmit(cmd *cobra.Command, record map[string]any, channelID, lastPostID string, noCoverage bool) error {
	if !noCoverage && channelID != "" && lastPostID != "" && c.cfg.Actor.ID != "" {
		_ = c.reportCoverage(cmd, channelID, lastPostID, 0, true, "")
	}
	return c.output(cmd.OutOrStdout(), mustJSON(record))
}

func mustJSON(value any) json.RawMessage {
	raw, err := json.Marshal(map[string]any{"chat": value})
	if err != nil {
		return json.RawMessage(`{"chat":null}`)
	}
	return raw
}

func (c *commands) chatRead() *cobra.Command {
	channel, since, incompleteReason := "", "", ""
	limit := 50
	includeOwn := false
	noCoverage := false
	cmd := &cobra.Command{Use: "read", Short: "Read recent channel posts with own-echo suppression", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&channel, "channel", "", "Channel ID to read (required)")
	cmd.Flags().IntVar(&limit, "limit", 50, "Newest posts to fetch, 1-200")
	cmd.Flags().StringVar(&since, "since", "", "Exclusive cursor: stop at this post ID")
	cmd.Flags().BoolVar(&includeOwn, "include-own", false, "Include the worker's own posts in the output")
	cmd.Flags().StringVar(&incompleteReason, "incomplete-reason", "", "Explicit reason to record when catch-up is incomplete")
	cmd.Flags().BoolVar(&noCoverage, "no-coverage", false, "Skip reporting the read as a coverage receipt")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if channel == "" {
			return errors.New("--channel is required")
		}
		if limit < 1 || limit > 200 {
			return errors.New("--limit must be between 1 and 200")
		}
		mm, err := mmConnect(c.cfg.CAFile)
		if err != nil {
			return err
		}
		self, err := mm.me()
		if err != nil {
			return err
		}
		order, posts, err := mm.channelPosts(channel, limit)
		if err != nil {
			return err
		}
		selected := make([]mmPost, 0, len(order))
		foundSince := since == ""
		var newest string
		for _, id := range order {
			if id == since {
				foundSince = true
				break
			}
			post, ok := posts[id]
			if !ok || post.ID == "" {
				continue
			}
			if newest == "" {
				newest = post.ID
			}
			if post.UserID == self && !includeOwn {
				continue
			}
			selected = append(selected, post)
		}
		for i, j := 0, len(selected)-1; i < j; i, j = i+1, j-1 {
			selected[i], selected[j] = selected[j], selected[i]
		}
		caughtUp := foundSince
		reason := incompleteReason
		if since == "" {
			caughtUp = false
			if reason == "" {
				reason = "bounded_snapshot"
			}
		} else if !foundSince {
			caughtUp = false
			if reason == "" {
				reason = "cursor_not_found"
			}
		}
		if !noCoverage && newest != "" && c.cfg.Actor.ID != "" {
			_ = c.reportCoverage(cmd, channel, newest, 0, caughtUp, reason)
		}
		return c.output(cmd.OutOrStdout(), mustJSON(map[string]any{
			"channel_id":        channel,
			"posts":             selected,
			"caught_up":         caughtUp,
			"incomplete_reason": reasonOrNull(reason, caughtUp),
			"suppressed_own":    !includeOwn,
		}))
	}
	return cmd
}

func reasonOrNull(reason string, caughtUp bool) any {
	if caughtUp || reason == "" {
		return nil
	}
	return reason
}

func (c *commands) reportCoverage(cmd *cobra.Command, channelID, lastPostID string, lastVersion int, caughtUp bool, reason string) error {
	payload := map[string]any{
		"last_post_id": lastPostID,
		"last_version": lastVersion,
		"caught_up":    caughtUp,
	}
	if !caughtUp && reason != "" {
		payload["incomplete_reason"] = reason
	}
	return c.request(cmd, http.MethodPost, "conversations/coverage/"+c.cfg.Actor.ID+"/"+channelID, nil, payload)
}

func (c *commands) chatReport() *cobra.Command {
	channel, lastPostID, reason := "", "", ""
	version := 0
	caughtUp := false
	cmd := &cobra.Command{Use: "report", Short: "Record an explicit coverage receipt for a channel", Args: cobra.NoArgs}
	cmd.Flags().StringVar(&channel, "channel", "", "Channel ID (required)")
	cmd.Flags().StringVar(&lastPostID, "last-post-id", "", "Newest post observed (required)")
	cmd.Flags().IntVar(&version, "last-version", 0, "Post version observed")
	cmd.Flags().BoolVar(&caughtUp, "caught-up", false, "Mark catch-up complete")
	cmd.Flags().StringVar(&reason, "incomplete-reason", "", "Explicit reason when catch-up is incomplete")
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if channel == "" || lastPostID == "" {
			return errors.New("--channel and --last-post-id are required")
		}
		if err := c.cfg.Actor.Validate(); err != nil {
			return err
		}
		return c.reportCoverage(cmd, channel, lastPostID, version, caughtUp, reason)
	}
	return cmd
}
