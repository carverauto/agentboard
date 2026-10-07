package worker

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// mmTransport is a worker-member connection, separate from the board runtime
// capability and the server's lifecycle bridge token. It never follows redirects.
type mmTransport struct {
	base  *url.URL
	http  *http.Client
	tls   *tls.Config
	token string
}

type mmHTTPError struct {
	Status     int
	RetryAfter time.Duration
}

func (e *mmHTTPError) Error() string {
	return "Mattermost member request unavailable (HTTP " + strconv.Itoa(e.Status) + ")"
}

func openMMTransport(baseURL, caFile, tokenFile, expectedUser string) (*mmTransport, error) {
	u, err := url.Parse(baseURL)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("invalid Mattermost base URL")
	}
	loopback := u.Hostname() == "localhost"
	if ip := net.ParseIP(u.Hostname()); ip != nil {
		loopback = ip.IsLoopback()
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && loopback) {
		return nil, errors.New("Mattermost requires HTTPS; HTTP allowed only on loopback")
	}
	if expectedUser == "" {
		return nil, errors.New("explicit immutable Mattermost member identity required")
	}
	data, err := ReadProtected(tokenFile, 4096)
	if err != nil {
		return nil, err
	}
	token := strings.TrimSpace(string(data))
	if token == "" || strings.ContainsAny(token, "\r\n\t ") {
		return nil, errors.New("invalid protected Mattermost token reference")
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, errors.New("Mattermost CA unavailable")
		}
		roots, err := x509.SystemCertPool()
		if err != nil {
			roots = x509.NewCertPool()
		}
		if !roots.AppendCertsFromPEM(pem) {
			return nil, errors.New("Mattermost CA contains no certificate")
		}
		tlsConfig.RootCAs = roots
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = tlsConfig
	transport.DialContext = (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	transport.TLSHandshakeTimeout = 10 * time.Second
	transport.ResponseHeaderTimeout = 30 * time.Second
	return &mmTransport{base: u, tls: tlsConfig, token: token, http: &http.Client{
		Transport: transport, Timeout: 45 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (m *mmTransport) endpoint(path string, query url.Values) string {
	u := *m.base
	u.Path = strings.TrimRight(u.Path, "/") + "/api/v4/" + path
	u.RawQuery = query.Encode()
	return u.String()
}

func (m *mmTransport) get(ctx context.Context, path string, query url.Values, into any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, m.endpoint(path, query), nil)
	if err != nil {
		return errors.New("invalid Mattermost member request")
	}
	request.Header.Set("Authorization", "Bearer "+m.token)
	response, err := m.http.Do(request)
	if err != nil {
		return errors.New("Mattermost member request failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		retry := time.Duration(0)
		if seconds, err := strconv.ParseInt(response.Header.Get("Retry-After"), 10, 32); err == nil && seconds > 0 {
			retry = time.Duration(seconds) * time.Second
		} else if until, err := http.ParseTime(response.Header.Get("Retry-After")); err == nil {
			retry = max(time.Until(until), 0)
		}
		return &mmHTTPError{Status: response.StatusCode, RetryAfter: retry}
	}
	if response.Header.Get("Has-Inaccessible-Posts") == "true" {
		return errors.New("Mattermost retention or plan limit makes catch-up incomplete")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, (8<<20)+1))
	if err != nil || len(data) > 8<<20 || json.Unmarshal(data, into) != nil {
		return errors.New("invalid or oversized Mattermost member response")
	}
	return nil
}

func (m *mmTransport) verify(ctx context.Context, expectedUser string) error {
	var user struct {
		ID      string `json:"id"`
		Roles   string `json:"roles"`
		Deleted int64  `json:"delete_at"`
	}
	if err := m.get(ctx, "users/me", nil, &user); err != nil {
		return err
	}
	if user.ID != expectedUser || user.Deleted != 0 {
		return errors.New("Mattermost authenticated identity does not match enrolled worker")
	}
	for _, role := range strings.Fields(user.Roles) {
		if role == "system_admin" {
			return errors.New("Mattermost steady-state inbox refuses administrator credentials")
		}
	}
	return nil
}

type mmLiveEvent struct {
	Event string                     `json:"event"`
	Data  map[string]json.RawMessage `json:"data"`
	Seq   int64                      `json:"seq"`
}

// subscribe waits for authenticated hello before allowing any history reread.
// A bounded buffer holds arrivals while REST pages are fetched. Overflow closes
// the stream and must be recorded as an incomplete gap, never silently dropped.
func (m *mmTransport) subscribe(ctx context.Context) (*websocket.Conn, <-chan mmLiveEvent, <-chan error, error) {
	u, _ := url.Parse(m.endpoint("websocket", nil))
	if u.Scheme == "https" {
		u.Scheme = "wss"
	} else {
		u.Scheme = "ws"
	}
	dialer := websocket.Dialer{TLSClientConfig: m.tls, HandshakeTimeout: 15 * time.Second, Proxy: http.ProxyFromEnvironment}
	conn, response, err := dialer.DialContext(ctx, u.String(), http.Header{"Authorization": {"Bearer " + m.token}})
	if err != nil {
		if response != nil {
			return nil, nil, nil, &mmHTTPError{Status: response.StatusCode}
		}
		return nil, nil, nil, errors.New("Mattermost subscription unavailable")
	}
	conn.SetReadLimit(1 << 20)
	_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	var hello mmLiveEvent
	if conn.ReadJSON(&hello) != nil || hello.Event != "hello" {
		conn.Close()
		return nil, nil, nil, errors.New("Mattermost authenticated subscription hello missing")
	}
	_ = conn.SetReadDeadline(time.Time{})
	events, failures := make(chan mmLiveEvent, 4096), make(chan error, 1)
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	go func() {
		defer stop()
		defer conn.Close()
		defer close(events)
		defer close(failures)
		seq := hello.Seq
		for {
			var event mmLiveEvent
			if conn.ReadJSON(&event) != nil {
				failures <- errors.New("Mattermost subscription disconnected")
				return
			}
			if event.Seq != seq+1 {
				failures <- errors.New("Mattermost live sequence gap; REST recovery required")
				return
			}
			seq = event.Seq
			select {
			case events <- event:
			case <-ctx.Done():
				return
			default:
				failures <- errors.New("Mattermost live buffer overflow; catch-up incomplete")
				return
			}
		}
	}()
	return conn, events, failures, nil
}
