package client_test

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
)

const accessIDFixture = "access-client-id-fixture.access"
const accessSecretFixture = "access-client-secret-fixture-012345678901234567890"
const boardTokenFixture = "abt_board-bearer-fixture-012345678901234567890"
const runtimeTokenFixture = "runtime-capability-fixture-012345678901234567890"
const captainTokenFixture = "captain-capability-fixture-012345678901234567890"

func accessFile(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "access-fixture.json")
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func accessJSON(id, secret string) string {
	data, _ := json.Marshal(map[string]string{"client_id": id, "client_secret": secret})
	return string(data)
}

func accessTLSConfig(t *testing.T, server *httptest.Server) config.Config {
	t.Helper()
	ca := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600); err != nil {
		t.Fatal(err)
	}
	return config.Config{
		URL: server.URL, CAFile: ca,
		AccessServiceTokenFile: accessFile(t, accessJSON(accessIDFixture, accessSecretFixture)),
	}
}

func TestAccessHeadersPreserveBoardRuntimeAndCaptainAuthorization(t *testing.T) {
	for _, kind := range []string{"board", "runtime", "captain", "edge-only"} {
		t.Run(kind, func(t *testing.T) {
			wantToken := map[string]string{"board": boardTokenFixture, "runtime": runtimeTokenFixture, "captain": captainTokenFixture}[kind]
			var calls atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.Header.Get("Cf-Access-Client-Id") != accessIDFixture || r.Header.Get("Cf-Access-Client-Secret") != accessSecretFixture {
					t.Error("edge credential headers missing or changed")
				}
				wantAuthorization := ""
				if wantToken != "" {
					wantAuthorization = "Bearer " + wantToken
				}
				if r.Header.Get("Authorization") != wantAuthorization {
					t.Error("edge credentials replaced or changed board Authorization")
				}
				wantProtocol := ""
				if kind == "runtime" {
					wantProtocol = "1"
				}
				if r.Header.Get("X-Agentboard-Worker-Protocol") != wantProtocol {
					t.Error("wrong worker protocol")
				}
				if r.URL.Path != "/board/api/v1/meta" {
					t.Error("request escaped configured board path")
				}
				io.WriteString(w, `{"api_version":1}`)
			}))
			defer server.Close()
			cfg := accessTLSConfig(t, server)
			cfg.URL += "/board"
			cfg.Token = boardTokenFixture
			var c *client.Client
			var err error
			switch kind {
			case "runtime":
				c, err = client.NewRuntime(cfg, runtimeTokenFixture)
			case "captain":
				c, err = client.NewCaptain(cfg, captainTokenFixture)
			default:
				cfg.Token = wantToken
				c, err = client.New(cfg)
			}
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			if _, err := c.JSON(context.Background(), http.MethodGet, "meta", nil, nil); err != nil || calls.Load() != 1 {
				t.Fatalf("authenticated request failed: %v, calls %d", err, calls.Load())
			}
		})
	}
}

func TestAccessHeadersAreAbsentUnlessConfigured(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cf-Access-Client-Id") != "" || r.Header.Get("Cf-Access-Client-Secret") != "" {
			t.Error("unconfigured Access headers sent")
		}
		io.WriteString(w, `{}`)
	}))
	defer server.Close()
	if _, err := api(t, server.URL).JSON(context.Background(), http.MethodGet, "meta", nil, nil); err != nil {
		t.Fatal(err)
	}
}

func TestAccessCredentialsRequireHTTPSEvenOnLoopback(t *testing.T) {
	path := accessFile(t, accessJSON(accessIDFixture, accessSecretFixture))
	for _, address := range []string{"http://localhost:4000", "http://127.0.0.1:4000", "http://[::1]:4000", "http://board.example"} {
		c, err := client.New(config.Config{URL: address, AccessServiceTokenFile: path})
		if err == nil {
			c.Close()
			t.Fatalf("Access credentials accepted over HTTP: %s", address)
		}
		if !strings.Contains(err.Error(), "HTTPS") {
			t.Fatal("missing HTTPS guidance")
		}
	}
}

func TestAccessFileRejectsUnsafeOrMalformedInputs(t *testing.T) {
	valid := accessJSON(accessIDFixture, accessSecretFixture)
	inputs := map[string]string{
		"empty": "", "not-json": accessSecretFixture, "array": "[]", "null": "null",
		"missing-secret": `{"client_id":"` + accessIDFixture + `"}`,
		"missing-id":     `{"client_secret":"` + accessSecretFixture + `"}`,
		"empty-id":       accessJSON("", accessSecretFixture), "empty-secret": accessJSON(accessIDFixture, ""),
		"unknown-field":   strings.TrimSuffix(valid, "}") + `,"extra":"` + accessSecretFixture + `"}`,
		"duplicate-field": strings.TrimSuffix(valid, "}") + `,"client_id":"another"}`,
		"wrong-case":      strings.ReplaceAll(valid, "client_id", "CLIENT_ID"),
		"null-value":      `{"client_id":null,"client_secret":"` + accessSecretFixture + `"}`,
		"number-value":    `{"client_id":123,"client_secret":"` + accessSecretFixture + `"}`,
		"trailing-json":   valid + "{}", "trailing-garbage": valid + accessSecretFixture,
		"long-id":       accessJSON(strings.Repeat("i", 1025), accessSecretFixture),
		"long-secret":   accessJSON(accessIDFixture, strings.Repeat("s", 1025)),
		"oversize-file": valid + strings.Repeat(" ", 4096),
	}
	for _, character := range []string{"\r", "\n", "\t", " ", "\x00", "\x1f", "\x7f", "é"} {
		inputs[fmt.Sprintf("id-control-%x", character)] = accessJSON(accessIDFixture+character, accessSecretFixture)
		inputs[fmt.Sprintf("secret-control-%x", character)] = accessJSON(accessIDFixture, accessSecretFixture+character)
	}
	for name, contents := range inputs {
		t.Run(name, func(t *testing.T) {
			path := accessFile(t, contents)
			c, err := client.New(config.Config{URL: "https://board.example", AccessServiceTokenFile: path})
			if err == nil {
				c.Close()
				t.Fatal("malformed Access credentials accepted")
			}
			for _, private := range []string{path, accessIDFixture, accessSecretFixture} {
				if strings.Contains(err.Error(), private) {
					t.Fatal("credential content or protected path leaked in error")
				}
			}
		})
	}
}

func TestAccessFileRequiresProtectedRegularNonSymlink(t *testing.T) {
	valid := accessJSON(accessIDFixture, accessSecretFixture)
	for _, kind := range []string{"missing", "symlink", "directory", "fifo", "group-readable", "world-readable", "executable", "read-only"} {
		t.Run(kind, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "unsafe-access.json")
			var err error
			switch kind {
			case "missing":
			case "symlink":
				err = os.Symlink(accessFile(t, valid), path)
			case "directory":
				err = os.Mkdir(path, 0600)
			case "fifo":
				err = syscall.Mkfifo(path, 0600)
			default:
				mode := map[string]os.FileMode{"group-readable": 0640, "world-readable": 0644, "executable": 0700, "read-only": 0400}[kind]
				err = os.WriteFile(path, []byte(valid), mode)
			}
			if err != nil {
				t.Fatal(err)
			}
			finished := make(chan error, 1)
			go func() {
				c, err := client.New(config.Config{URL: "https://board.example", AccessServiceTokenFile: path})
				if c != nil {
					c.Close()
				}
				finished <- err
			}()
			select {
			case err := <-finished:
				if err == nil {
					t.Fatal("unsafe credential file accepted")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("unsafe credential file blocked instead of being rejected")
			}
		})
	}
}

func TestAccessFileRejectsDifferentOwner(t *testing.T) {
	path := accessFile(t, accessJSON(accessIDFixture, accessSecretFixture))
	if err := os.Chown(path, os.Geteuid()+1, -1); err != nil {
		t.Skip("test runner cannot create a fixture owned by a different user")
	}
	c, err := client.New(config.Config{URL: "https://board.example", AccessServiceTokenFile: path})
	if err == nil {
		c.Close()
		t.Fatal("another user's credential file accepted")
	}
}

func TestAccessRedirectsNeverForwardCredentials(t *testing.T) {
	for _, status := range []int{301, 302, 303, 307, 308} {
		for _, destination := range []string{"other-origin", "same-origin", "http-downgrade"} {
			t.Run(fmt.Sprintf("%d-%s", status, destination), func(t *testing.T) {
				var targetCalls, sourceCalls atomic.Int32
				target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					targetCalls.Add(1)
					io.WriteString(w, `{}`)
				}))
				defer target.Close()
				server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					sourceCalls.Add(1)
					location := target.URL + "/redirected"
					if destination == "same-origin" {
						location = "/redirected"
					} else if destination == "http-downgrade" {
						location = strings.Replace(location, "https:", "http:", 1)
					}
					http.Redirect(w, r, location, status)
				}))
				defer server.Close()
				cfg := accessTLSConfig(t, server)
				cfg.Token = boardTokenFixture
				c, err := client.New(cfg)
				if err != nil {
					t.Fatal(err)
				}
				defer c.Close()
				_, err = c.JSON(context.Background(), http.MethodPost, "tasks", nil, map[string]string{"title": "fixture"})
				if err == nil || targetCalls.Load() != 0 || sourceCalls.Load() != 1 {
					t.Fatal("credential-bearing redirect followed or accepted")
				}
			})
		}
	}
}

func escapedJSONString(value string) string {
	var out strings.Builder
	for _, character := range value {
		fmt.Fprintf(&out, `\u%04x`, character)
	}
	return out.String()
}

func assertNoReflectedCredentials(t *testing.T, raw []byte) {
	t.Helper()
	for _, secret := range []string{accessIDFixture, accessSecretFixture, boardTokenFixture} {
		if strings.Contains(string(raw), secret) || strings.Contains(string(raw), escapedJSONString(secret)) {
			t.Fatal("credential reflected in response")
		}
	}
	if !strings.Contains(string(raw), "[redacted]") {
		t.Fatal("missing redacted marker")
	}
}

func TestAccessRedactsJSONErrorsAndEscapedReflections(t *testing.T) {
	for _, status := range []int{200, 403} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				message := escapedJSONString(accessIDFixture) + " / " + escapedJSONString(accessSecretFixture) + " / " + escapedJSONString(boardTokenFixture)
				w.WriteHeader(status)
				if status == 200 {
					io.WriteString(w, `{"`+escapedJSONString(accessIDFixture)+`":"`+message+`","number":9007199254740993}`)
				} else {
					io.WriteString(w, `{"error":{"code":"`+escapedJSONString(accessSecretFixture)+`","message":"`+message+`"}}`)
				}
			}))
			defer server.Close()
			cfg := accessTLSConfig(t, server)
			cfg.Token = boardTokenFixture
			c, err := client.New(cfg)
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			raw, err := c.JSON(context.Background(), http.MethodGet, "meta", nil, nil)
			if status == 200 {
				if err != nil {
					t.Fatal(err)
				}
				assertNoReflectedCredentials(t, raw)
				if !json.Valid(raw) || !strings.Contains(string(raw), "9007199254740993") {
					t.Fatal("redaction damaged JSON or numeric precision")
				}
			} else {
				var failure *client.Error
				if !errors.As(err, &failure) {
					t.Fatal("expected API error")
				}
				encoded, _ := json.Marshal(failure)
				assertNoReflectedCredentials(t, encoded)
			}
		})
	}
}

func TestAccessOnlyWatchRedactsCredentialsAcrossChunks(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cf-Access-Client-Secret") != accessSecretFixture || r.Header.Get("Authorization") != "" {
			t.Error("watch did not preserve edge-only authentication")
		}
		w.Header().Set("Content-Type", "application/x-ndjson")
		line := `{"id":"` + escapedJSONString(accessIDFixture) + `","secret":"` + escapedJSONString(accessSecretFixture) + `"}` + "\n"
		for start := 0; start < len(line); start += 11 {
			end := min(start+11, len(line))
			io.WriteString(w, line[start:end])
			w.(http.Flusher).Flush()
		}
	}))
	defer server.Close()
	c, err := client.New(accessTLSConfig(t, server))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	resp, err := c.Stream(context.Background(), "messages/watch", url.Values{"cursor": {"fixture"}})
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	assertNoReflectedCredentials(t, raw)
	if !json.Valid(raw) {
		t.Fatal("watch redaction damaged a record")
	}
}
