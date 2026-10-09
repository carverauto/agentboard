package worker_test

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/worker"
)

const accessIDFixture = "worker-edge-client-fixture.access"
const accessSecretFixture = "worker-edge-secret-fixture-012345678901234567890"
const hostTokenFixture = "worker-host-token-fixture-012345678901234567890"
const receiptTokenFixture = "worker-receipt-token-fixture-012345678901234567890"

func protectedFixture(t *testing.T, path, data string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}

func workerFixture(t *testing.T) worker.Config {
	t.Helper()
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "worker-token")
	protectedFixture(t, tokenFile, hostTokenFixture+"\n")
	protectedFixture(t, tokenFile+".receipt", receiptTokenFixture+"\n")
	accessFile := filepath.Join(dir, "access.json")
	protectedFixture(t, accessFile, `{"client_id":"`+accessIDFixture+`","client_secret":"`+accessSecretFixture+`"}`)
	return worker.Config{
		Version: worker.Protocol, URL: "https://board.example", JournalDir: filepath.Join(dir, "journal"),
		AccessServiceTokenFile: accessFile,
		Bindings: []worker.Binding{{
			Agent: "worker-auth", Model: "fixture-model", Harness: "codex", Host: "host", Server: "server",
			Session: "session", Generation: "fixture-generation", Adapter: "manual", Epoch: 1,
			Socket: filepath.Join(dir, "worker.sock"), TokenFile: tokenFile,
		}},
	}
}

func loadFixture(t *testing.T, cfg worker.Config) (worker.Config, error) {
	t.Helper()
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "worker.json")
	protectedFixture(t, path, string(data))
	return worker.Load(path)
}

func TestOpenAPIAccessPreservesHostAndReceiptCapabilities(t *testing.T) {
	for _, source := range []string{"config", "environment", "matching-both"} {
		for _, receipt := range []bool{false, true} {
			role := "host"
			if receipt {
				role = "receipt"
			}
			t.Run(source+"-"+role, func(t *testing.T) {
				t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
				cfg := workerFixture(t)
				if source != "config" {
					t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", cfg.AccessServiceTokenFile)
					if source == "environment" {
						cfg.AccessServiceTokenFile = ""
					}
				}
				wantToken := hostTokenFixture
				method, action := http.MethodGet, "state"
				if receipt {
					wantToken = receiptTokenFixture
					method, action = http.MethodPost, "receipts"
				}
				var calls atomic.Int32
				server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls.Add(1)
					if r.Header.Get("Cf-Access-Client-Id") != accessIDFixture || r.Header.Get("Cf-Access-Client-Secret") != accessSecretFixture {
						t.Error("worker lost edge service credentials")
					}
					if r.Header.Get("Authorization") != "Bearer "+wantToken || r.Header.Get("X-Agentboard-Worker-Protocol") != "1" {
						t.Error("worker capability or protocol replaced by edge credentials")
					}
					if r.Header.Get("X-Agentboard-Agent") != cfg.Bindings[0].Agent || r.Header.Get("X-Agentboard-Model") != cfg.Bindings[0].Model || r.Header.Get("X-Agentboard-Harness") != cfg.Bindings[0].Harness {
						t.Error("worker attribution missing")
					}
					if r.Method != method || r.URL.Path != "/api/v1/workers/worker-auth/"+action {
						t.Error("wrong worker API route")
					}
					io.WriteString(w, `{"protocol_revision":1,"reflection":"`+accessIDFixture+" "+accessSecretFixture+" "+wantToken+`"}`)
				}))
				defer server.Close()
				cfg.URL = server.URL
				cfg.CAFile = filepath.Join(t.TempDir(), "ca.pem")
				protectedFixture(t, cfg.CAFile, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})))
				loaded, err := loadFixture(t, cfg)
				if err != nil {
					t.Fatal(err)
				}
				api, err := worker.OpenAPI(loaded, loaded.Bindings[0], receipt)
				if err != nil {
					t.Fatal(err)
				}
				defer api.Close()
				raw, err := api.Call(context.Background(), method, action, nil, nil)
				if err != nil || calls.Load() != 1 {
					t.Fatalf("worker API request failed: %v, calls %d", err, calls.Load())
				}
				for _, value := range []string{accessIDFixture, accessSecretFixture, wantToken} {
					if strings.Contains(string(raw), value) {
						t.Fatal("worker API exposed a reflected credential")
					}
				}
			})
		}
	}
}

func TestWorkerAccessFileConflictingSourcesFailClosed(t *testing.T) {
	cfg := workerFixture(t)
	otherPath := filepath.Join(t.TempDir(), "other-access.json")
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", otherPath)
	if _, err := loadFixture(t, cfg); err == nil || !strings.Contains(err.Error(), "conflicts") {
		t.Fatal("worker configuration accepted conflicting credential sources")
	}
	for _, receipt := range []bool{false, true} {
		api, err := worker.OpenAPI(cfg, cfg.Bindings[0], receipt)
		if api != nil {
			api.Close()
		}
		if err == nil || !strings.Contains(err.Error(), "conflicts") {
			t.Fatal("worker OpenAPI accepted conflicting credential sources")
		}
		if strings.Contains(err.Error(), otherPath) || strings.Contains(err.Error(), cfg.AccessServiceTokenFile) {
			t.Fatal("credential path leaked in conflict error")
		}
	}
}

func TestWorkerAccessConfigPathMustBeAbsolute(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	cfg := workerFixture(t)
	cfg.AccessServiceTokenFile = "access.json"
	if _, err := loadFixture(t, cfg); err == nil || !strings.Contains(err.Error(), "absolute") {
		t.Fatal("relative worker credential config path accepted")
	}
}

func TestWorkerAccessEnvironmentRelativePathResolvesConsistently(t *testing.T) {
	cfg := workerFixture(t)
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	relative, err := filepath.Rel(cwd, cfg.AccessServiceTokenFile)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", relative)
	loaded, err := loadFixture(t, cfg)
	if err != nil {
		t.Fatal("matching relative environment and absolute config paths rejected")
	}
	api, err := worker.OpenAPI(loaded, loaded.Bindings[0], false)
	if err != nil {
		t.Fatal(err)
	}
	api.Close()
}

func TestWorkerAccessCredentialsKeepHTTPSAndFileGuards(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	for _, invalid := range []string{"http", "unprotected-file", "malformed-file"} {
		t.Run(invalid, func(t *testing.T) {
			cfg := workerFixture(t)
			switch invalid {
			case "http":
				cfg.URL = "http://localhost:4000"
			case "unprotected-file":
				if err := os.Chmod(cfg.AccessServiceTokenFile, 0644); err != nil {
					t.Fatal(err)
				}
			case "malformed-file":
				protectedFixture(t, cfg.AccessServiceTokenFile, `{"client_secret":"`+accessSecretFixture+`"}`)
			}
			for _, receipt := range []bool{false, true} {
				api, err := worker.OpenAPI(cfg, cfg.Bindings[0], receipt)
				if api != nil {
					api.Close()
				}
				if err == nil {
					t.Fatal("worker bypassed HTTPS or credential-file guard")
				}
				if strings.Contains(err.Error(), accessSecretFixture) {
					t.Fatal("worker exposed credential in validation error")
				}
			}
		})
	}
}
