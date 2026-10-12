package owner

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

//go:embed testdata/*.mjs
var fixtures embed.FS

// os/exec copies stderr concurrently until Wait. Failure diagnostics may be read
// while the invented peer is still alive, so both operations must synchronize.
type synchronizedLog struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (b *synchronizedLog) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.Write(p)
}
func (b *synchronizedLog) String() string { b.mu.Lock(); defer b.mu.Unlock(); return b.buffer.String() }
func TestSynchronizedLog(t *testing.T) {
	var b synchronizedLog
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				_, _ = b.Write([]byte("x"))
				_ = b.String()
			}
		}()
	}
	wg.Wait()
	if len(b.String()) != 4000 {
		t.Fatal("lost diagnostic output")
	}
}

func fixtureApproval(t *testing.T, pid int) Approval {
	t.Helper()
	peer, err := InspectProcess(pid)
	if err != nil {
		t.Fatal(err)
	}
	return Approval{ID: "invented-fixture", AuthorityRevision: 1, InitializeApproved: true, Deadline: time.Now().Add(10 * time.Second), Peer: peer,
		Identity: Identity{Endpoint: Endpoint{ServerID: "invented", EndpointID: "invented", Profile: "codex-durable-advisory-v1", NativeVersion: "0.162.0", ProtocolSource: "rust-v0.162.0", SchemaSHA256: strings.Repeat("a", 64), ExperimentalAPI: true, QueueAPI: true}, Recipient: Recipient{ThreadID: "11111111-1111-4111-8111-111111111111", IdentityKind: "durable-conversation-v1", EnrollmentRevision: 123, BindingEpoch: 3, Persistent: true, TopLevel: true}}}
}
func TestMissingApprovalRefusesBeforeDial(t *testing.T) {
	if _, err := Dial(context.Background(), "/does/not/exist", Approval{}); err == nil {
		t.Fatal("missing approval accepted")
	}
}
func TestUnsupportedPlatform(t *testing.T) {
	if runtime.GOOS == "linux" {
		t.Skip("non-Linux refusal")
	}
	if _, err := InspectProcess(os.Getpid()); err == nil {
		t.Fatal("unsupported process proof accepted")
	}
}
func TestPhysicalPeerProof(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux process proof")
	}
	tmp := shortSocketTemp(t)
	path := filepath.Join(tmp, "s")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err = os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	approval := fixtureApproval(t, os.Getpid())
	for name, change := range map[string]func(*Approval){
		"wrong-pid": func(a *Approval) { a.Peer.PID++ }, "wrong-start": func(a *Approval) { a.Peer.StartTicks++ },
		"wrong-boot":             func(a *Approval) { a.Peer.BootID = "00000000-0000-4000-8000-000000000000" },
		"wrong-hash":             func(a *Approval) { a.Peer.ExecutableSHA256 = strings.Repeat("0", 64) },
		"no-initialize-approval": func(a *Approval) { a.InitializeApproved = false },
		"strict-profile":         func(a *Approval) { a.Identity.Endpoint.Profile = "codex-native-queue-v1" },
		"caller-generation":      func(a *Approval) { a.Identity.Endpoint.Generation = "invented" },
	} {
		t.Run(name, func(t *testing.T) {
			a := approval
			change(&a)
			o, err := Dial(context.Background(), path, a)
			if o != nil {
				o.Retire()
			}
			if err == nil {
				t.Fatal("accepted invalid proof")
			}
		})
	}
	o, err := Dial(context.Background(), path, approval)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(o.approval.Identity.Endpoint.Generation, "process:") {
		t.Fatal("no kernel-derived process generation")
	}
	o.Retire()
	o.Retire()
	if err = o.Start(exec.Command("unused")); err == nil {
		t.Fatal("retired owner restarted")
	}
	if err = os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if _, err = Dial(context.Background(), path, approval); err == nil {
		t.Fatal("writable socket accepted")
	}
}
func integrationFiles(t *testing.T) (string, string) {
	t.Helper()
	if os.Getenv("OWNER_INTEGRATION") != "1" {
		t.Skip("UNRUN: set OWNER_INTEGRATION=1 and OWNER_WS_ARCHIVE for real Go/Node inherited-FD integration")
	}
	if runtime.GOOS != "linux" {
		t.Skip("Linux-only peer proof; Darwin fails closed")
	}
	root, err := filepath.Abs("../../..")
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
		body, e := fixtures.ReadFile("testdata/" + name)
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(stage, name), body, 0600); e != nil {
			t.Fatal(e)
		}
	}
	return node, stage
}
func TestInheritedFDIntegration(t *testing.T) {
	node, stage := integrationFiles(t)
	for _, mode := range []string{"happy", "retire", "pipe-eof", "lease", "lose-add", "wrong-approval", "wrong-fd", "fd-substitution"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			tmp := shortSocketTemp(t)
			path := filepath.Join(tmp, "s")
			log := filepath.Join(tmp, "requests")
			journal := filepath.Join(tmp, "journal")
			if err := os.Mkdir(journal, 0700); err != nil {
				t.Fatal(err)
			}
			peer := exec.CommandContext(ctx, node, filepath.Join(stage, "peer.mjs"), path, log, mode)
			peer.Env = []string{"WS_NO_BUFFER_UTIL=1", "WS_NO_UTF_8_VALIDATE=1"}
			var peerErr synchronizedLog
			peer.Stderr = &peerErr
			out, err := peer.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err = peer.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { _ = peer.Process.Kill(); _ = peer.Wait() }()
			ready := bufio.NewScanner(out)
			if !ready.Scan() || ready.Text() != "ready" {
				t.Fatal("peer not ready", peerErr.String())
			}
			approval := fixtureApproval(t, peer.Process.Pid)
			if mode == "lease" {
				approval.Deadline = time.Now().Add(800 * time.Millisecond)
			}
			o, err := Dial(ctx, path, approval)
			if err != nil {
				t.Fatal(err)
			}
			defer o.Retire()
			if mode == "fd-substitution" {
				other, e := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
				if e != nil {
					t.Fatal(e)
				}
				o.mu.Lock()
				old := o.conn
				o.conn = other // Deliberate fixture fault: retain stamp of the ORIGINAL socket.
				o.mu.Unlock()
				defer old.Close()
			}
			child := exec.CommandContext(ctx, node, filepath.Join(stage, "client.mjs"), mode, journal)
			child.Env = peer.Env
			var childErr synchronizedLog
			child.Stderr = &childErr
			childOut, err := child.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err = o.Start(child); err != nil {
				t.Fatal(err)
			}
			lines := bufio.NewScanner(childOut)
			var output []string
			for lines.Scan() {
				line := lines.Text()
				output = append(output, line)
				if line == "accepted" && mode == "retire" {
					o.Retire()
				}
				if line == "accepted" && mode == "pipe-eof" {
					_ = o.controlOut.Close()
				}
			}
			if err = child.Wait(); err != nil {
				t.Fatalf("child failed: %v, output %v, stderr %s, peer %s", err, output, childErr.String(), peerErr.String())
			}
			if ctx.Err() != nil {
				t.Fatal("integration timed out")
			}
			body, err := os.ReadFile(log)
			if os.IsNotExist(err) {
				body = nil
			} else if err != nil {
				t.Fatal(err)
			}
			adds, initializes := 0, 0
			for _, line := range bytes.Split(bytes.TrimSpace(body), []byte{'\n'}) {
				if len(line) == 0 {
					continue
				}
				var frame map[string]any
				if err = json.Unmarshal(line, &frame); err != nil {
					t.Fatal(err)
				}
				if frame["method"] == "thread/queue/add" {
					adds++
					params := frame["params"].(map[string]any)
					text := params["input"].([]any)[0].(map[string]any)["text"].(string)
					if !strings.Contains(text, "durable advisory notice v1") {
						t.Fatal("wrong advisory frame")
					}
				}
				if frame["method"] == "initialize" {
					initializes++
				}
			}
			if mode == "wrong-approval" || mode == "wrong-fd" || mode == "fd-substitution" {
				if initializes != 0 || adds != 0 {
					t.Fatal("refused owner wrote native RPC")
				}
			} else if initializes != 1 || adds != 1 {
				t.Fatalf("expected exactly one initialize and add, got %d %d", initializes, adds)
			}
		})
	}
}

func TestApprovalAndEnvironment(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux inventory")
	}
	a := fixtureApproval(t, os.Getpid())
	if !valid(a) {
		t.Fatal("fixture descriptor rejected")
	}
	for _, change := range []func(*Approval){
		func(a *Approval) { a.AuthorityRevision = 0 }, func(a *Approval) { a.Deadline = time.Now().Add(31 * time.Second) },
		func(a *Approval) { a.Deadline = time.Now().Add(-time.Second) }, func(a *Approval) { a.Deadline = time.Time{} },
		func(a *Approval) { a.Identity.Recipient.IdentityKind = "loaded-session" }, func(a *Approval) { a.Identity.Recipient.BindingEpoch = 0 },
		func(a *Approval) { a.Identity.Recipient.EnrollmentRevision = maxSafe + 1 }, func(a *Approval) { a.Identity.Endpoint.SchemaSHA256 = "self-report" },
	} {
		copy := a
		change(&copy)
		if valid(copy) {
			t.Fatal("invalid authority accepted")
		}
	}
	safe := []string{"WS_NO_BUFFER_UTIL=1", "WS_NO_UTF_8_VALIDATE=1"}
	if !safeEnvironment(safe) {
		t.Fatal("safe environment refused")
	}
	for _, env := range [][]string{nil, {}, {"WS_NO_BUFFER_UTIL=0", "WS_NO_UTF_8_VALIDATE=1"}} {
		if safeEnvironment(env) {
			t.Fatal("unsafe environment accepted")
		}
	}
	for _, entry := range []string{"NODE_OPTIONS=--require=foreign", "NODE_PATH=/foreign", "LD_PRELOAD=/foreign", "OPENAI_API_KEY=secret", "AWS_SECRET_ACCESS_KEY=secret", "WS_NO_BUFFER_UTIL=1"} {
		env := append(append([]string{}, safe...), entry)
		if safeEnvironment(env) {
			t.Fatal("unsafe environment accepted", strings.Split(entry, "=")[0])
		}
	}
}

func TestProcessInventory(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux inventory")
	}
	p, err := InspectProcess(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(exe)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	if p.PID != os.Getpid() || p.UID != uint32(os.Geteuid()) || p.StartTicks == 0 || !uuid.MatchString(p.BootID) || p.ExecutableSHA256 != hex.EncodeToString(sum[:]) {
		t.Fatal("process inventory differs from executing image")
	}
	if _, err = InspectProcess(-1); err == nil {
		t.Fatal("invalid PID accepted")
	}
}

// Keep sockaddr_un paths bounded even under long Bazel TEST_TMPDIR prefixes.
func shortSocketTemp(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "ab-owner-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}
