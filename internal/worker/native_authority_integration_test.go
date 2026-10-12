package worker

// This fixture uses an invented HTTPS authority service and invented Unix peer.
// The separate Phoenix packaged fixture proves the real producer/CLI contract.
// Never substitute a real native daemon, account, capability or deployment.
import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/agentboard/internal/nativequeue/owner"
)

// os/exec drains stderr concurrently. Diagnostics may be read while the peer
// still runs, including when an unrelated assertion fails; bytes.Buffer alone
// is not safe on that failure path.
type nativeAuthorityFixtureLog struct {
	mu   sync.Mutex
	data bytes.Buffer
}

func (b *nativeAuthorityFixtureLog) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.Write(p)
}

func (b *nativeAuthorityFixtureLog) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.String()
}

func TestNativeAuthorityDiagnosticBuffer(t *testing.T) {
	var output nativeAuthorityFixtureLog
	var group sync.WaitGroup
	group.Add(2)
	go func() {
		defer group.Done()
		for i := 0; i < 100; i++ {
			_, _ = output.Write([]byte("fixture diagnostic\n"))
		}
	}()
	go func() {
		defer group.Done()
		for i := 0; i < 100; i++ {
			_ = output.String()
		}
	}()
	group.Wait()
	if strings.Count(output.String(), "fixture diagnostic\n") != 100 {
		t.Fatal("fixture stderr diagnostics lost")
	}
}

func authorityIntegrationFiles(t *testing.T) (string, string) {
	t.Helper()
	if os.Getenv("OWNER_INTEGRATION") != "1" {
		t.Skip("UNRUN: set OWNER_INTEGRATION=1 and OWNER_WS_ARCHIVE for real Go/Node inherited-FD integration")
	}
	if runtime.GOOS != "linux" {
		t.Skip("Linux-only peer proof; Darwin fails closed")
	}
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	node := os.Getenv("OWNER_NODE")
	archive := os.Getenv("OWNER_WS_ARCHIVE")
	if runfiles := os.Getenv("TEST_SRCDIR"); runfiles != "" {
		root = filepath.Join(runfiles, os.Getenv("TEST_WORKSPACE"))
		if node == "" {
			files, _ := filepath.Glob(filepath.Join(runfiles, "*worker_node_linux_x64*", "bin", "node"))
			if len(files) == 1 {
				node = files[0]
			}
		}
		if archive == "" {
			files, _ := filepath.Glob(filepath.Join(runfiles, "*codex_rpc_ws*", "file", "*"))
			for _, f := range files {
				if s, e := os.Stat(f); e == nil && s.Mode().IsRegular() && !strings.HasSuffix(f, "BUILD.bazel") {
					archive = f
				}
			}
		}
	}
	if node == "" {
		node, err = exec.LookPath("node")
		if err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal("pinned ws archive required:", err)
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != "ca9b3798b2e11ce8fac6713f50ef0501aa12b09b330623c1dc409dff94e7abc8" {
		t.Fatal("ws checksum mismatch")
	}
	stage := t.TempDir()
	ws := filepath.Join(stage, "node_modules", "ws")
	if err = os.MkdirAll(ws, 0700); err != nil {
		t.Fatal(err)
	}
	gz, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			t.Fatal(e)
		}
		name := strings.TrimPrefix(h.Name, "package/")
		if name == h.Name || filepath.IsAbs(name) || strings.Contains(name, "..") {
			t.Fatal("bad archive entry")
		}
		dest := filepath.Join(ws, name)
		switch h.Typeflag {
		case tar.TypeDir:
			err = os.MkdirAll(dest, 0700)
		case tar.TypeReg:
			if h.Size > 1<<20 {
				t.Fatal("oversized archive file")
			}
			err = os.MkdirAll(filepath.Dir(dest), 0700)
			if err == nil {
				var body []byte
				body, err = io.ReadAll(tr)
				if err == nil {
					err = os.WriteFile(dest, body, 0600)
				}
			}
		default:
			t.Fatal("unexpected archive entry type")
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	modules := filepath.Join(stage, "codex")
	if err = os.Mkdir(modules, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"rpc-wire.mjs", "inherited-client.mjs", "owner-control.mjs", "transport.mjs", "advisory-mapping.mjs", "journal.mjs"} {
		body, e := os.ReadFile(filepath.Join(root, "internal", "nativequeue", "codex", name))
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(modules, name), body, 0600); e != nil {
			t.Fatal(e)
		}
	}
	for _, name := range []string{"peer.mjs", "client.mjs"} {
		body, e := os.ReadFile(filepath.Join(root, "internal", "nativequeue", "owner", "testdata", name))
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(stage, name), body, 0600); e != nil {
			t.Fatal(e)
		}
	}
	return node, stage
}

func TestNativeAuthorityOwnerIntegration(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	node, stage := authorityIntegrationFiles(t)
	for _, mode := range []string{"revision", "error", "denied", "malformed", "expiry"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			// Keep Unix paths below sockaddr_un's fixed size even under Bazel runfiles.
			dir, err := os.MkdirTemp("/tmp", "ab-authority-")
			if err != nil {
				t.Fatal(err)
			}
			defer os.RemoveAll(dir)
			socket, log, journal := filepath.Join(dir, "s"), filepath.Join(dir, "requests"), filepath.Join(dir, "journal")
			if err := os.Mkdir(journal, 0700); err != nil {
				t.Fatal(err)
			}
			peer := exec.CommandContext(ctx, node, filepath.Join(stage, "peer.mjs"), socket, log, "retire")
			peer.Env = []string{"WS_NO_BUFFER_UTIL=1", "WS_NO_UTF_8_VALIDATE=1"}
			var peerErr nativeAuthorityFixtureLog
			peer.Stderr = &peerErr
			peerOut, err := peer.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err = peer.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { _ = peer.Process.Kill(); _ = peer.Wait() }()
			ready := bufio.NewScanner(peerOut)
			if !ready.Scan() || ready.Text() != "ready" {
				t.Fatal("invented peer unavailable", peerErr.String())
			}
			process, err := owner.InspectProcess(peer.Process.Pid)
			if err != nil {
				t.Fatal(err)
			}
			manifest := NativeManifest{ManifestVersion: 1, ID: "invented-fixture", WorkerID: "invented-worker", HostID: "invented-host", EnrollmentRevision: 123, BindingEpoch: 3, SessionID: "invented-binding", PaneID: "invented-generation", SocketPath: socket, InitializeApproved: true, Peer: process,
				Endpoint: owner.Endpoint{ServerID: "invented", EndpointID: "invented", Profile: "codex-durable-advisory-v1", NativeVersion: "0.162.0", ProtocolSource: "rust-v0.162.0", SchemaSHA256: strings.Repeat("a", 64), ExperimentalAPI: true, QueueAPI: true}, Recipient: owner.Recipient{ThreadID: "11111111-1111-4111-8111-111111111111", IdentityKind: "durable-conversation-v1", EnrollmentRevision: 123, BindingEpoch: 3, Persistent: true, TopLevel: true}}
			hash, err := NativeManifestSHA256(manifest)
			if err != nil {
				t.Fatal(err)
			}
			baseline := NativeAuthoritySnapshot{ProtocolRevision: 1, AuthorityContractRevision: 1, WorkerID: manifest.WorkerID, HostID: manifest.HostID, AuthorityRevision: 1, ApprovalID: &manifest.ID, ManifestSHA256: &hash, Manifest: &manifest, EnrollmentRevision: 123, BindingEpoch: 3, Permitted: true, ReasonCodes: []string{}, ValidForMS: 5000}
			const token = "invented-host-authority-fixture-only-0123456789"
			var calls atomic.Int32
			var outstanding atomic.Int32
			service := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if outstanding.Add(1) != 1 {
					t.Error("authority requests overlapped")
				}
				defer outstanding.Add(-1)
				n := calls.Add(1)
				if r.Method != "GET" || r.URL.Path != "/api/v1/hosts/invented-host/workers/invented-worker/native-authority" || r.Header.Get("Authorization") != "Bearer "+token || r.Header.Get("X-Agentboard-Worker-Protocol") != "1" {
					t.Error("invented host authority scope changed")
					w.WriteHeader(403)
					return
				}
				snapshot := baseline
				if n > 1 {
					switch mode {
					case "revision":
						snapshot.AuthorityRevision++
					case "error":
						w.WriteHeader(503)
						_, _ = io.WriteString(w, `{"error":{"code":"unavailable","message":"invented feed gap"}}`)
						return
					case "malformed":
						_, _ = io.WriteString(w, `{"protocol_revision":1}`)
						return
					case "denied":
						snapshot.Permitted = false
						snapshot.ValidForMS = 0
						snapshot.ReasonCodes = []string{"native_approval_retired"}
					}
				}
				_ = json.NewEncoder(w).Encode(snapshot)
			}))
			defer service.Close()
			ca := filepath.Join(dir, "ca.pem")
			if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: service.Certificate().Raw}), 0600); err != nil {
				t.Fatal(err)
			}
			tokenFile := filepath.Join(dir, "host-token")
			if err := os.WriteFile(tokenFile, []byte(token), 0600); err != nil {
				t.Fatal(err)
			}
			config := Config{URL: service.URL, CAFile: ca}
			binding := Binding{Agent: manifest.WorkerID, Host: manifest.HostID, TokenFile: tokenFile, Model: "fixture", Harness: "codex"}
			api, err := OpenAPI(config, binding, false)
			if err != nil {
				t.Fatal(err)
			}
			defer api.Close()
			snapshot, err := api.FetchNativeAuthority(ctx)
			if err != nil {
				t.Fatal(err)
			}
			approval, err := BuildNativeApproval(manifest, snapshot, snapshot.RequestStarted())
			if err != nil {
				t.Fatal(err)
			}
			native, err := owner.Dial(ctx, socket, approval)
			if err != nil {
				t.Fatal(err)
			}
			defer native.Retire()
			child := exec.CommandContext(ctx, node, filepath.Join(stage, "client.mjs"), "retire", journal)
			child.Env = peer.Env
			var childErr nativeAuthorityFixtureLog
			child.Stderr = &childErr
			childOut, err := child.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err = native.Start(child); err != nil {
				t.Fatal(err)
			}
			lines := bufio.NewScanner(childOut)
			var output []string
			var pollResult chan error
			for lines.Scan() {
				line := lines.Text()
				output = append(output, line)
				if line == "accepted" {
					if pollResult != nil {
						t.Fatal("native add replayed")
					}
					pollResult = make(chan error, 1)
					go func() { pollResult <- api.PollNativeAuthority(ctx, manifest, snapshot, native.Retire) }()
				}
			}
			if err = child.Wait(); err != nil {
				t.Fatalf("same-FD child failed: %v output=%v stderr=%s peer=%s", err, output, childErr.String(), peerErr.String())
			}
			if pollResult == nil {
				t.Fatal("child did not accept exact notice")
			}
			select {
			case err = <-pollResult:
				if err == nil {
					t.Fatal("poll did not retire")
				}
			case <-ctx.Done():
				t.Fatal("authority retirement did not complete")
			}
			if !strings.Contains(strings.Join(output, "\n"), "retired-history-retained") {
				t.Fatal("child did not observe retirement and preserve historical acceptance")
			}
			if mode == "expiry" {
				if calls.Load() < 2 || calls.Load() > 5 {
					t.Fatalf("expiry did not keep bounded serial polling: %d", calls.Load())
				}
				elapsed := time.Since(snapshot.RequestStarted())
				if elapsed < NativeAuthorityLifetime || elapsed > NativeAuthorityLifetime+time.Second {
					t.Fatalf("immutable original expiry changed: %v", elapsed)
				}
			} else if calls.Load() != 2 {
				t.Fatalf("unexpected HTTP reconnect/retry: %d", calls.Load())
			}
			body, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			adds, initializes := 0, 0
			for _, line := range bytes.Split(bytes.TrimSpace(body), []byte{'\n'}) {
				var frame map[string]any
				if json.Unmarshal(line, &frame) != nil {
					t.Fatal("bad native fixture log")
				}
				if frame["method"] == "initialize" {
					initializes++
				}
				if frame["method"] == "thread/queue/add" {
					adds++
				}
			}
			if adds != 1 || initializes != 1 {
				t.Fatalf("native reconnect/replay: initializes=%d adds=%d", initializes, adds)
			}
		})
	}
}
