// Package client implements the Phoenix API transport. It never accesses a database.
package client

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/carverauto/agentboard/internal/config"
)

const MaxResponseBytes = 16 << 20
const requestBudget = 120 * time.Second
const maxRetries = 3
const maxAccessServiceTokenBytes = 4096

type Error struct {
	Code       string        `json:"code"`
	Message    string        `json:"message"`
	Status     int           `json:"-"`
	RetryAfter time.Duration `json:"-"`
}

func (e *Error) Error() string { return e.Message }
func (e *Error) ExitCode() int {
	switch e.Code {
	case "invalid_input", "invalid_context":
		return 2
	case "not_found":
		return 3
	case "conflict":
		return 4
	default:
		return 1
	}
}

type Client struct {
	base               *url.URL
	http               *http.Client
	actor              config.Actor
	token              string
	accessClientID     string
	accessClientSecret string
	workerProtocol     string
	captain            bool
	workerCaptain      bool
}

// NewRuntime uses the existing HTTPS/redirect/retry transport with scoped auth.
// The caller must load the capability from protected storage; it is never an argument.
func NewRuntime(cfg config.Config, token string) (*Client, error) {
	if token == "" || strings.ContainsAny(token, "\r\n\t ") {
		return nil, errors.New("invalid runtime capability")
	}
	cfg.Token, cfg.TokenFile = "", ""
	c, err := New(cfg)
	if err != nil {
		return nil, err
	}
	c.token, c.workerProtocol = token, "1"
	return c, nil
}

// NewCaptain reuses the guarded transport without advertising worker runtime protocol.
func NewCaptain(cfg config.Config, token string) (*Client, error) {
	if len(token) < 32 || strings.ContainsAny(token, "\r\n\t ") {
		return nil, errors.New("captain capability is malformed")
	}
	cfg.Token, cfg.TokenFile = "", ""
	c, err := New(cfg)
	if err != nil {
		return nil, err
	}
	c.token, c.captain = token, true
	return c, nil
}

// WorkerControl uses the worker API's independent captain boundary. Its
// closed operation set prevents captain headers from reaching ordinary routes.
// A request-local copy preserves concurrent ordinary bearer requests.
func (c *Client) WorkerControl(ctx context.Context, operation, workerID string, payload any) (json.RawMessage, error) {
	if !c.captain || c.token == "" {
		return nil, errors.New("worker control requires a captain client")
	}
	var path string
	switch {
	case operation == "provision" && workerID == "":
		path = "workers/provision"
	case operation == "revoke" && config.ValidID(workerID):
		path = "workers/" + workerID + "/revoke"
	default:
		return nil, errors.New("unsupported worker captain operation")
	}
	request := *c
	request.workerCaptain = true
	return request.JSON(ctx, http.MethodPost, path, nil, payload)
}

func New(cfg config.Config) (*Client, error) {
	token, err := agentBearer(cfg)
	if err != nil {
		return nil, err
	}

	u, err := url.Parse(cfg.URL)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("AGENTBOARD_URL must be an HTTPS base URL without credentials, query, or fragment")
	}
	loopback := u.Hostname() == "localhost"
	if ip := net.ParseIP(u.Hostname()); ip != nil {
		loopback = ip.IsLoopback()
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && loopback) {
		return nil, errors.New("API connections require HTTPS; HTTP is allowed only on loopback")
	}
	if cfg.AccessServiceTokenFile != "" && u.Scheme != "https" {
		return nil, errors.New("Cloudflare Access service credentials require HTTPS, including on loopback")
	}
	accessID, accessSecret, err := accessServiceToken(cfg.AccessServiceTokenFile)
	if err != nil {
		return nil, err
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if cfg.CAFile != "" {
		pem, err := os.ReadFile(cfg.CAFile)
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
	return &Client{base: u, actor: cfg.Actor, token: token, accessClientID: accessID, accessClientSecret: accessSecret, http: &http.Client{
		Transport:     transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (c *Client) Close() { c.http.CloseIdleConnections() }

func (c *Client) JSON(ctx context.Context, method, path string, query url.Values, payload any) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, requestBudget)
	defer cancel()
	var body []byte
	var err error
	if payload != nil {
		body, err = json.Marshal(payload)
		if err != nil {
			return nil, errors.New("cannot encode API request")
		}
		if len(body) > 5<<20 {
			return nil, errors.New("API request exceeds 5 MiB")
		}
	}
	resp, err := c.open(ctx, method, path, query, body, "application/json")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, MaxResponseBytes+1))
	if err != nil || len(data) > MaxResponseBytes {
		return nil, failure("response_failed", uncertain(method, "API response could not be read"))
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, c.redactError(responseError(resp.StatusCode, data))
	}
	if !json.Valid(data) {
		return nil, failure("invalid_response", uncertain(method, "API returned invalid JSON"))
	}
	return json.RawMessage(c.redactData(data)), nil
}

// Stream opens an NDJSON watch. Its lifetime is controlled by the caller's context.
func (c *Client) Stream(ctx context.Context, path string, query url.Values) (*http.Response, error) {
	resp, err := c.open(ctx, http.MethodGet, path, query, nil, "application/x-ndjson")
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		defer resp.Body.Close()
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		return nil, c.redactError(responseError(resp.StatusCode, data))
	}
	if !strings.HasPrefix(resp.Header.Get("Content-Type"), "application/x-ndjson") {
		resp.Body.Close()
		return nil, failure("invalid_response", "API watch returned an unexpected content type")
	}
	if c.token != "" || c.accessClientID != "" {
		scanner := bufio.NewScanner(resp.Body)
		scanner.Buffer(make([]byte, 64<<10), MaxResponseBytes)
		resp.Body = &redactedStream{body: resp.Body, scanner: scanner, redact: c.redactData}
	}
	return resp, nil
}

func (c *Client) open(ctx context.Context, method, path string, query url.Values, body []byte, accept string) (*http.Response, error) {
	u := *c.base
	u.Path = strings.TrimRight(c.base.Path, "/") + "/api/v1/" + strings.TrimLeft(path, "/")
	u.RawQuery = query.Encode()
	started := time.Now()
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, failure("cancelled", "API request cancelled")
		}
		req, err := http.NewRequestWithContext(ctx, method, u.String(), bytes.NewReader(body))
		if err != nil {
			return nil, failure("invalid_request", "cannot construct API request")
		}
		req.Header.Set("Accept", accept)
		req.Header.Set("User-Agent", "agentboard-cli/0.1")
		// Edge authentication is distinct from the board's own bearer capability.
		// Requests use only the configured base; redirects are never followed.
		if c.accessClientID != "" {
			req.Header.Set("CF-Access-Client-Id", c.accessClientID)
			req.Header.Set("CF-Access-Client-Secret", c.accessClientSecret)
		}
		if c.workerCaptain {
			req.Header.Set("X-Agentboard-Captain-Token", c.token)
			req.Header.Set("X-Agentboard-Worker-Protocol", "1")
		} else if c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
			if c.workerProtocol != "" {
				req.Header.Set("X-Agentboard-Worker-Protocol", c.workerProtocol)
			}
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		if c.actor.ID != "" {
			req.Header.Set("X-Agentboard-Agent", c.actor.ID)
		}
		if c.actor.Model != "" {
			req.Header.Set("X-Agentboard-Model", c.actor.Model)
		}
		if c.actor.Harness != "" {
			req.Header.Set("X-Agentboard-Harness", c.actor.Harness)
		}
		resp, err := c.http.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil, failure("cancelled", uncertain(method, "API request cancelled"))
			}
			return nil, failure("connection_failed", uncertain(method, "API connection failed; check reachability and HTTPS trust"))
		}
		if resp.StatusCode != http.StatusTooManyRequests {
			return resp, nil
		}
		delay := retryDelay(resp.Header.Get("Retry-After"), attempt, time.Now())
		io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		resp.Body.Close()
		if attempt >= maxRetries {
			return nil, &Error{Code: "rate_limited", Message: "API rate limit persists after three retries", RetryAfter: delay}
		}
		remaining := requestBudget - time.Since(started)
		if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) < remaining {
			remaining = time.Until(deadline)
		}
		if delay >= remaining {
			return nil, &Error{Code: "rate_limited", Message: "API Retry-After exceeds the remaining request deadline", RetryAfter: delay}
		}
		if err := wait(ctx, delay); err != nil {
			return nil, failure("cancelled", "API retry cancelled")
		}
	}
}

func retryDelay(value string, attempt int, now time.Time) time.Duration {
	value = strings.TrimSpace(value)
	delay := time.Duration(1<<attempt) * time.Second
	if seconds, err := strconv.ParseUint(value, 10, 64); err == nil {
		// Avoid overflow and never cap a valid server delay below its advertised floor.
		if seconds > uint64((time.Duration(1<<63-1)-time.Second)/time.Second) {
			return time.Duration(1<<63 - 1)
		}
		delay = time.Duration(seconds) * time.Second
	} else if errors.Is(err, strconv.ErrRange) {
		return time.Duration(1<<63 - 1)
	} else if when, err := http.ParseTime(value); err == nil {
		delay = when.Sub(now)
		if delay < 0 {
			delay = 0
		}
	}
	jitter := time.Duration(rand.IntN(250)+1) * time.Millisecond
	if delay > time.Duration(1<<63-1)-jitter {
		return time.Duration(1<<63 - 1)
	}
	return delay + jitter
}

func wait(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func responseError(status int, data []byte) error {
	var envelope struct {
		Error Error `json:"error"`
	}
	if json.Unmarshal(data, &envelope) == nil && envelope.Error.Code != "" && envelope.Error.Message != "" {
		envelope.Error.Status = status
		// Status is authoritative; unknown remote codes cannot turn an outage into an input error.
		switch status {
		case 400, 422:
			envelope.Error.Code = "invalid_input"
		case 404:
			envelope.Error.Code = "not_found"
		case 409:
			envelope.Error.Code = "conflict"
		default:
			envelope.Error.Code = "server_error"
		}
		return &envelope.Error
	}
	return &Error{Code: "server_error", Message: fmt.Sprintf("API returned HTTP %d", status), Status: status}
}

func failure(code, message string) error { return &Error{Code: code, Message: message} }
func uncertain(method, message string) string {
	if method != http.MethodGet {
		return message + "; write outcome may be unknown, inspect board state before repeating"
	}
	return message
}

// Error bodies are untrusted and may reflect any authentication header.
func (c *Client) redactError(err error) error {
	if e, ok := err.(*Error); ok {
		redact := c.credentialRedactor().Replace
		e.Message = redact(e.Message)
		if redact(e.Code) != e.Code {
			e.Code = "invalid_response"
		}
	}
	return err
}

func (c *Client) redactData(data []byte) []byte {
	if c.token == "" && c.accessClientID == "" {
		return data
	}
	redact := c.credentialRedactor().Replace
	// Decode strings before redaction so alternate JSON escapes cannot expose a
	// reflected credential. Preserve all other bytes, including numeric values.
	var out bytes.Buffer
	for pos := 0; pos < len(data); {
		if data[pos] != '"' {
			out.WriteByte(data[pos])
			pos++
			continue
		}
		end := pos + 1
		for end < len(data) {
			if data[end] == '\\' {
				end += 2
				continue
			}
			if data[end] == '"' {
				break
			}
			end++
		}
		if end >= len(data) {
			out.WriteString(redact(string(data[pos:])))
			break
		}
		quoted := data[pos : end+1]
		var value string
		if json.Unmarshal(quoted, &value) == nil {
			if redacted := redact(value); redacted != value {
				quoted, _ = json.Marshal(redacted)
			}
		}
		out.Write(quoted)
		pos = end + 1
	}
	// Invalid watch records may also contain an unquoted reflection. They are
	// still untrusted output, even though the caller will reject malformed JSON.
	if !json.Valid(data) {
		return []byte(redact(out.String()))
	}
	return out.Bytes()
}

func (c *Client) credentialRedactor() *strings.Replacer {
	var replacements []string
	for _, secret := range []string{c.token, c.accessClientID, c.accessClientSecret} {
		if secret != "" {
			replacements = append(replacements, secret, "[redacted]")
		}
	}
	return strings.NewReplacer(replacements...)
}

type redactedStream struct {
	body    io.ReadCloser
	scanner *bufio.Scanner
	redact  func([]byte) []byte
	pending []byte
}

func (r *redactedStream) Read(dst []byte) (int, error) {
	if len(dst) == 0 {
		return 0, nil
	}
	if len(r.pending) == 0 {
		if !r.scanner.Scan() {
			if err := r.scanner.Err(); err != nil {
				return 0, err
			}
			return 0, io.EOF
		}
		r.pending = append(r.redact(r.scanner.Bytes()), '\n')
	}
	n := copy(dst, r.pending)
	r.pending = r.pending[n:]
	return n, nil
}
func (r *redactedStream) Close() error { return r.body.Close() }

// agentBearer resolves ordinary board credentials separately from transport trust.
func agentBearer(cfg config.Config) (string, error) {
	token := cfg.Token
	if token == "" && cfg.TokenFile != "" {
		data, err := readProtectedCredentialFile(cfg.TokenFile, "AGENTBOARD_TOKEN_FILE", 256)
		if err != nil {
			return "", err
		}
		token = strings.TrimSpace(string(data))
		if token == "" {
			return "", errors.New("agent credential file is empty")
		}
	}
	if token != "" && (len(token) > 256 || strings.ContainsAny(token, "\r\n\t ")) {
		return "", errors.New("invalid AGENTBOARD_TOKEN")
	}

	return token, nil
}

// accessServiceToken loads operator-provisioned edge credentials only from an
// explicit protected file. Neither credentials nor the supplied path enter errors.
func accessServiceToken(path string) (string, string, error) {
	if path == "" {
		return "", "", nil
	}
	data, err := readProtectedCredentialFile(path, "AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", maxAccessServiceTokenBytes)
	if err != nil {
		return "", "", err
	}
	invalid := errors.New("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE must contain only nonempty client_id and client_secret string fields with valid credential values")
	decoder := json.NewDecoder(bytes.NewReader(data))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return "", "", invalid
	}
	values := make(map[string]string, 2)
	for decoder.More() {
		field, err := decoder.Token()
		if err != nil || (field != "client_id" && field != "client_secret") {
			return "", "", invalid
		}
		key := field.(string)
		if _, duplicate := values[key]; duplicate {
			return "", "", invalid
		}
		var value string
		if decoder.Decode(&value) != nil || !validAccessCredential(value) {
			return "", "", invalid
		}
		values[key] = value
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || len(values) != 2 {
		return "", "", invalid
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return "", "", invalid
	}
	return values["client_id"], values["client_secret"], nil
}

func validAccessCredential(value string) bool {
	if len(value) == 0 || len(value) > 1024 {
		return false
	}
	for i := 0; i < len(value); i++ {
		// Credentials are opaque visible ASCII header values, without whitespace
		// or control characters. In particular, never accept header injection.
		if value[i] < '!' || value[i] > '~' {
			return false
		}
	}
	return true
}

func readProtectedCredentialFile(path, label string, maxBytes int64) ([]byte, error) {
	// Validate the descriptor instead of a racy path stat. NONBLOCK ensures a
	// malicious FIFO is rejected promptly rather than blocking before f.Stat.
	fd, err := syscall.Open(filepath.Clean(path), syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, errors.New("cannot open protected " + label)
	}
	f := os.NewFile(uintptr(fd), "protected credential")
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return nil, errors.New(label + " must be a regular 0600 file")
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !ok || st.Uid != uint32(os.Geteuid()) {
		return nil, errors.New(label + " must belong to the current user")
	}
	data, err := io.ReadAll(io.LimitReader(f, maxBytes+1))
	if err != nil || int64(len(data)) > maxBytes {
		return nil, errors.New("invalid protected " + label)
	}
	return data, nil
}
