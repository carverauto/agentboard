package worker

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/agentboard/internal/nativequeue/owner"
)

func nativeFixture() NativeManifest {
	return NativeManifest{ManifestVersion: 1, ID: "fixture-approval", WorkerID: "worker-native", HostID: "fixture-host", EnrollmentRevision: 1791750000000000, BindingEpoch: 3, SessionID: "fixture-session", PaneID: "fixture-pane", SocketPath: "/tmp/fixture-native.sock", InitializeApproved: true,
		Endpoint:  owner.Endpoint{ServerID: "fixture-server", EndpointID: "fixture-endpoint", Profile: "codex-durable-advisory-v1", NativeVersion: "0.162.0", ProtocolSource: "rust-v0.162.0", SchemaSHA256: strings.Repeat("a", 64), ExperimentalAPI: true, QueueAPI: true},
		Recipient: owner.Recipient{ThreadID: "11111111-1111-4111-8111-111111111111", IdentityKind: "durable-conversation-v1", EnrollmentRevision: 1791750000000000, BindingEpoch: 3, Persistent: true, TopLevel: true},
		Peer:      owner.ProcessIdentity{PID: 42, UID: uint32(os.Geteuid()), BootID: "22222222-2222-4222-8222-222222222222", StartTicks: 12345, ExecutableSHA256: strings.Repeat("b", 64)}}
}
func nativeSnapshotFixture(m NativeManifest) NativeAuthoritySnapshot {
	hash, _ := NativeManifestSHA256(m)
	id := m.ID
	return NativeAuthoritySnapshot{ProtocolRevision: 1, AuthorityContractRevision: 1, WorkerID: m.WorkerID, HostID: m.HostID, AuthorityRevision: 1, ApprovalID: &id, ManifestSHA256: &hash, Manifest: &m, EnrollmentRevision: m.EnrollmentRevision, BindingEpoch: m.BindingEpoch, Permitted: true, ReasonCodes: []string{}, ValidForMS: 5000}
}
func nativeJSON(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestNativeManifestClosedSchemaAndCanonicalDigest(t *testing.T) {
	m := nativeFixture()
	m.Peer.UID = 0 // Fixed cross-language digest vector, independent of test-user UID.
	raw := nativeJSON(t, m)
	got, err := ParseNativeManifest(raw)
	if err != nil || got != m {
		t.Fatalf("fixture rejected: %v", err)
	}
	canonical, err := CanonicalNativeManifest(m)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(canonical), `{"binding_epoch":3,"endpoint":{"endpointId":`) {
		t.Fatalf("not recursive key order: %s", canonical)
	}
	hash, err := NativeManifestSHA256(m)
	if err != nil || len(hash) != 64 {
		t.Fatal(hash, err)
	}
	// Stable vector shared with the server suite, independent of Go struct order.
	const expectedHash = "a6a45399ab74964c650659ee0a0460d2b7698dd39ea264507eb416a5e1537b80"
	if hash != expectedHash {
		t.Fatalf("cross-language digest drift: %s", hash)
	}
	t.Logf("manifest vector SHA256 %s", hash)
	m.ID = ".leading-token"
	m.Endpoint.ServerID = ":leading"
	m.Endpoint.EndpointID = "_leading"
	if m.Validate() != nil {
		t.Fatal("owner-compatible punctuation rejected")
	}
	for _, bad := range []string{"contains space", strings.Repeat("a", 129), "<tag>"} {
		m.Endpoint.ServerID = bad
		if m.Validate() == nil {
			t.Fatal("owner-incompatible endpoint accepted")
		}
	}
	base := string(raw)
	bad := []string{
		`{}`, `null`, `[]`, base + `{}`, strings.Repeat(" ", MaxNativeAuthorityBytes+1),
		strings.Replace(base, `"manifest_version":1`, `"manifest_version":1,"manifest_version":1`, 1),
		strings.Replace(base, `"manifest_version":1`, `"Manifest_version":1`, 1),
		strings.Replace(base, `"manifest_version":1`, `"manifest_version":1,"extra":true`, 1),
		strings.Replace(base, `"manifest_version":1`, `"manifest_version":1.0`, 1),
		strings.Replace(base, `"manifest_version":1`, `"manifest_version":1e0`, 1),
		strings.Replace(base, `"bindingEpoch":3`, `"bindingEpoch":9007199254740992`, 1),
		strings.Replace(base, `"bindingEpoch":3`, `"bindingEpoch":4`, 1),
		strings.Replace(base, `"generation":""`, `"generation":null`, 1),
		strings.Replace(base, `"generation":""`, `"generation":"fake-native-lifetime"`, 1),
		strings.Replace(base, `"generation":""`, `"generation":"","generation":""`, 1),
		strings.Replace(base, `"initialize_approved":true`, `"initialize_approved":false`, 1),
		strings.Replace(base, `"pid":42`, `"pid":2147483648`, 1),
		strings.Replace(base, `"uid":0`, `"uid":4294967296`, 1),
		strings.Replace(base, `"uid":0`, `"uid":null`, 1),
		strings.Replace(base, `"startTicks":12345`, `"startTicks":9007199254740992`, 1),
		strings.Replace(base, `"host_id":"fixture-host"`, `"host_id":"\ud800"`, 1),
		strings.Replace(base, `"host_id":"fixture-host"`, `"host_id":"雪"`, 1),
		strings.Replace(base, `"socket_path":"/tmp/fixture-native.sock"`, `"socket_path":"/tmp/../fixture-native.sock"`, 1),
		strings.Replace(base, `"socket_path":"/tmp/fixture-native.sock"`, `"socket_path":"/tmp//fixture-native.sock"`, 1),
		strings.Replace(base, `"socket_path":"/tmp/fixture-native.sock"`, `"socket_path":"/"`, 1),
	}
	for i, value := range bad {
		if _, err := ParseNativeManifest([]byte(value)); err == nil {
			t.Fatalf("accepted malformed fixture %d", i)
		}
	}
	// ASCII strings that JSON escapes must still produce the shared literal digest.
	m = nativeFixture()
	m.SessionID = `fixture<&>"\\`
	canonical, err = CanonicalNativeManifest(m)
	if err != nil || strings.Contains(string(canonical), `\u003c`) {
		t.Fatalf("HTML escaped canonical JSON: %s %v", canonical, err)
	}
}
func TestReadNativeManifestRejectsLinksAndBounds(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.json")
	if err := os.WriteFile(path, nativeJSON(t, nativeFixture()), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadNativeManifest(path); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	parent := filepath.Join(dir, "directory-link")
	if err := os.Symlink(dir, parent); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", dir, link, filepath.Join(parent, "manifest.json"), filepath.Join(dir, "absent")} {
		if _, err := ReadNativeManifest(bad); err == nil {
			t.Fatalf("accepted unsafe input %q", bad)
		}
	}
	if err := os.WriteFile(path, []byte(strings.Repeat(" ", MaxNativeAuthorityBytes+1)), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadNativeManifest(path); err == nil {
		t.Fatal("accepted oversized file")
	}
}

type nativeTestClient struct {
	call func(context.Context, string, string, url.Values, any) (json.RawMessage, error)
}

func (c *nativeTestClient) JSON(context.Context, string, string, url.Values, any) (json.RawMessage, error) {
	panic("authority must not use retrying JSON")
}
func (c *nativeTestClient) JSONOnce(ctx context.Context, m, p string, q url.Values, b any) (json.RawMessage, error) {
	return c.call(ctx, m, p, q, b)
}
func (c *nativeTestClient) Close() {}
func nativeAPI(t *testing.T, s NativeAuthoritySnapshot) *API {
	t.Helper()
	return &API{agent: s.WorkerID, host: s.HostID, client: &nativeTestClient{call: func(ctx context.Context, method, path string, query url.Values, body any) (json.RawMessage, error) {
		if method != http.MethodGet || path != "hosts/fixture-host/workers/worker-native/native-authority" || len(query) != 0 || body != nil {
			t.Errorf("wrong authority read: %s %s", method, path)
		}
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > NativeAuthorityLifetime {
			t.Error("authority request lacks fixed budget")
		}
		return nativeJSON(t, s), nil
	}}}
}
func TestNativeAuthorityHostReadAndImmutableApproval(t *testing.T) {
	m := nativeFixture()
	s := nativeSnapshotFixture(m)
	api := nativeAPI(t, s)
	snapshot, err := api.FetchNativeAuthority(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	approval, err := BuildNativeApproval(m, snapshot, snapshot.RequestStarted())
	if err != nil {
		t.Fatal(err)
	}
	if approval.Deadline != snapshot.RequestStarted().Add(5*time.Second) || approval.Identity.Endpoint.Generation != "" || approval.Peer != m.Peer || approval.AuthorityRevision != 1 {
		t.Fatal("owner approval metadata or monotonic deadline changed")
	}
	if _, err := BuildNativeApproval(m, snapshot, time.Now()); err == nil {
		t.Fatal("caller timestamp replaced actual request start")
	}
	if _, err := BuildNativeApproval(m, snapshot, snapshot.RequestStarted().Round(0)); err == nil {
		t.Fatal("wall timestamp accepted")
	}
	parsed, err := ParseNativeAuthoritySnapshot(nativeJSON(t, s))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := BuildNativeApproval(m, parsed, time.Now()); err == nil {
		t.Fatal("untrusted parser result forged host authority")
	}
	changed := snapshot
	changed.AuthorityRevision++
	if _, err := BuildNativeApproval(m, changed, changed.RequestStarted()); err == nil {
		t.Fatal("mutable snapshot forged authority")
	}
	wrongUID := m
	wrongUID.Peer.UID++
	wrongSnapshot := nativeSnapshotFixture(wrongUID)
	wrongAPI := nativeAPI(t, wrongSnapshot)
	wrongRead, err := wrongAPI.FetchNativeAuthority(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := BuildNativeApproval(wrongUID, wrongRead, wrongRead.RequestStarted()); err == nil {
		t.Fatal("approval for foreign local UID accepted")
	}
	expected := m
	expected.Peer.StartTicks++
	if _, err := BuildNativeApproval(expected, snapshot, snapshot.RequestStarted()); err == nil {
		t.Fatal("expected immutable peer changed")
	}
	expired := snapshot
	expired.requestStarted = time.Now().Add(-6 * time.Second)
	if _, err := BuildNativeApproval(m, expired, expired.RequestStarted()); err == nil {
		t.Fatal("fresh-looking expired snapshot accepted")
	}
	// Request-start is always from the production fetch, never a server wall clock.
	if snapshot.RequestStarted() == snapshot.RequestStarted().Round(0) {
		t.Fatal("request start lost monotonic clock")
	}
}
func TestNativeAuthorityRejectsReceiptScopeAndWrongHost(t *testing.T) {
	m := nativeFixture()
	s := nativeSnapshotFixture(m)
	for _, mode := range []string{"receipt", "foreign-host", "foreign-worker", "bad-body", "denied"} {
		t.Run(mode, func(t *testing.T) {
			calls := 0
			api := &API{agent: m.WorkerID, host: m.HostID, receipt: mode == "receipt"}
			api.client = &nativeTestClient{call: func(context.Context, string, string, url.Values, any) (json.RawMessage, error) {
				calls++
				out := s
				switch mode {
				case "foreign-host":
					out.HostID = "foreign"
				case "foreign-worker":
					out.WorkerID = "foreign"
				case "bad-body":
					return []byte(`{"protocol_revision":1}`), nil
				case "denied":
					out.Permitted = false
					out.ValidForMS = 0
					out.ReasonCodes = []string{"profile_live_disabled"}
				}
				return nativeJSON(t, out), nil
			}}
			result, err := api.FetchNativeAuthority(context.Background())
			if mode == "receipt" && calls != 0 {
				t.Fatal("receipt sent as authority capability")
			}
			if mode == "denied" {
				if err != nil {
					t.Fatal(err)
				}
				if _, err = BuildNativeApproval(m, result, result.RequestStarted()); err == nil {
					t.Fatal("denial became owner")
				}
			} else if err == nil {
				t.Fatal("invalid authority accepted")
			}
		})
	}
}
func TestNativeAuthorityStrictSnapshots(t *testing.T) {
	s := nativeSnapshotFixture(nativeFixture())
	base := string(nativeJSON(t, s))
	bad := []string{
		strings.Replace(base, `"permitted":true`, `"permitted":true,"permitted":true`, 1),
		strings.Replace(base, `"valid_for_ms":5000`, `"valid_for_ms":5001`, 1),
		strings.Replace(base, `"valid_for_ms":5000`, `"valid_for_ms":null`, 1),
		strings.Replace(base, `"authority_contract_revision":1`, `"authority_contract_revision":2`, 1),
		strings.Replace(base, `"authority_revision":1`, `"authority_revision":9007199254740992`, 1),
		strings.Replace(base, `"reason_codes":[]`, `"reason_codes":null`, 1),
		strings.Replace(base, `"reason_codes":[]`, `"reason_codes":["disabled"]`, 1),
		strings.Replace(base, `"permitted":true`, `"permitted":false`, 1),
		strings.Replace(base, `"protocol_revision":1`, `"protocol_revision":1,"credentials":"bad"`, 1),
		strings.Replace(base, `"uid":`+strconv.Itoa(os.Geteuid()), `"UID":0`, 1),
	}
	for i, b := range bad {
		if _, err := ParseNativeAuthoritySnapshot([]byte(b)); err == nil {
			t.Fatalf("accepted malformed snapshot %d", i)
		}
	}
	denied := NativeAuthoritySnapshot{ProtocolRevision: 1, AuthorityContractRevision: 1, WorkerID: "worker-native", HostID: "fixture-host", ReasonCodes: []string{"native_approval_missing"}}
	if _, err := ParseNativeAuthoritySnapshot(nativeJSON(t, denied)); err != nil {
		t.Fatal("valid missing approval denied", err)
	}
	id := "orphan"
	denied.ApprovalID = &id
	if denied.Validate() == nil {
		t.Fatal("partial null metadata accepted")
	}
}
func TestNativeAuthorityPollNeverRenewsAndIsSerial(t *testing.T) {
	t.Parallel()
	m := nativeFixture()
	s := nativeSnapshotFixture(m)
	api := nativeAPI(t, s)
	initial, err := api.FetchNativeAuthority(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// Begin with 2.4 seconds left on the existing immutable owner. New successful
	// reads each carry 5 seconds but must not extend that original expiry.
	initial.requestStarted = time.Now().Add(-2600 * time.Millisecond)
	var active, maxActive, calls, retired atomic.Int32
	api.client = &nativeTestClient{call: func(ctx context.Context, _ string, _ string, _ url.Values, _ any) (json.RawMessage, error) {
		n := active.Add(1)
		if n > maxActive.Load() {
			maxActive.Store(n)
		}
		defer active.Add(-1)
		calls.Add(1)
		select {
		case <-time.After(30 * time.Millisecond):
			return nativeJSON(t, s), nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}}
	started := time.Now()
	err = api.PollNativeAuthority(context.Background(), m, initial, func() { retired.Add(1) })
	if err == nil || retired.Load() != 1 || maxActive.Load() != 1 || calls.Load() != 2 || time.Since(started) > 3*time.Second {
		t.Fatalf("renewal/concurrency drift: err=%v retire=%d active=%d calls=%d elapsed=%s", err, retired.Load(), maxActive.Load(), calls.Load(), time.Since(started))
	}
}
func TestNativeAuthorityPollRetiresOnEveryGapOrChange(t *testing.T) {
	for _, mode := range []string{"error", "revision", "denied", "manifest", "digest", "wrong-host", "malformed", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			m := nativeFixture()
			s := nativeSnapshotFixture(m)
			api := nativeAPI(t, s)
			initial, err := api.FetchNativeAuthority(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			calls, retired := 0, 0
			var mu sync.Mutex
			api.client = &nativeTestClient{call: func(context.Context, string, string, url.Values, any) (json.RawMessage, error) {
				mu.Lock()
				calls++
				mu.Unlock()
				out := nativeSnapshotFixture(m)
				switch mode {
				case "error":
					return nil, errors.New("fixture feed gap")
				case "revision":
					out.AuthorityRevision++
				case "denied":
					out.Permitted = false
					out.ValidForMS = 0
					out.ReasonCodes = []string{"retired"}
				case "manifest":
					out.Manifest.Peer.StartTicks++
					hash, _ := NativeManifestSHA256(*out.Manifest)
					out.ManifestSHA256 = &hash
				case "digest":
					hash := strings.Repeat("c", 64)
					out.ManifestSHA256 = &hash
				case "wrong-host":
					out.HostID = "foreign"
				case "malformed":
					return []byte(`{}`), nil
				}
				return nativeJSON(t, out), nil
			}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if mode == "cancelled" {
				cancel()
			}
			if err := api.PollNativeAuthority(ctx, m, initial, func() { retired++ }); err == nil {
				t.Fatal("feed continued after gap/change")
			}
			want := 1
			if mode == "cancelled" {
				want = 0
			}
			if retired != 1 || calls != want {
				t.Fatalf("unexpected reconnect/replay/retirement calls=%d retired=%d", calls, retired)
			}
		})
	}
}

type nativeResolveClient struct {
	call func(context.Context, string, string, url.Values, any) (json.RawMessage, error)
}

func (c *nativeResolveClient) JSON(ctx context.Context, m, p string, q url.Values, b any) (json.RawMessage, error) {
	return c.call(ctx, m, p, q, b)
}
func (c *nativeResolveClient) JSONOnce(context.Context, string, string, url.Values, any) (json.RawMessage, error) {
	panic("receiving gate is explicit exact-source POST")
}
func (c *nativeResolveClient) Close() {}
func nativeNoticeFixture(m NativeManifest) (Binding, WakeCallback, map[string]any) {
	binding := Binding{Agent: m.WorkerID, Host: m.HostID, Session: m.SessionID, Generation: m.PaneID, Epoch: m.BindingEpoch, Repos: []string{"fixture/repo"}}
	callback := WakeCallback{Attempt: "33333333-3333-4333-8333-333333333333", Intent: "44444444-4444-4444-8444-444444444444", ReasonHash: strings.Repeat("c", 64), PayloadHash: strings.Repeat("d", 64), Recipient: WakeRecipient{Agent: m.WorkerID, Host: m.HostID, Repo: "fixture/repo", Enrollment: m.EnrollmentRevision, Epoch: m.BindingEpoch, Session: m.SessionID, Generation: m.PaneID}}
	notice := map[string]any{"attemptId": callback.Attempt, "source": map[string]any{"kind": "agentboard_wake_attempt", "id": callback.Attempt, "version": callback.PayloadHash, "uri": "https://board.example/api/v1/hosts/fixture-host/wake-intents/worker-native/resolve"}, "recipient": m.Recipient, "bindingEpoch": m.BindingEpoch, "dispatchGeneration": 7, "wakeCallback": callback}
	return binding, callback, notice
}
func TestNativeNoticeResolvesExactFrozenSourceBeforeExposure(t *testing.T) {
	manifest := nativeFixture()
	binding, callback, notice := nativeNoticeFixture(manifest)
	for _, actionable := range []bool{false, true} {
		t.Run(map[bool]string{false: "denied", true: "actionable"}[actionable], func(t *testing.T) {
			calls := 0
			source := WakeSource{Kind: "board_message", ID: "42", Version: "fixture-version"}
			reservation := &WakeReservation{Protocol: 1, Intent: callback.Intent, ReasonHash: callback.ReasonHash, PayloadHash: callback.PayloadHash, Attempt: callback.Attempt, Recipient: callback.Recipient, Source: source}
			response := WakeResolution{Protocol: 1, Actionable: actionable, Reservation: reservation, ReasonCodes: []string{"source_handled"}}
			if actionable {
				response.ReasonCodes = []string{}
				response.Source = &WakeSourceMaterial{WakeSource: source, Message: json.RawMessage(`{"id":42,"body":"untrusted prose"}`)}
			}
			api := &API{agent: manifest.WorkerID, host: manifest.HostID, receipt: true, baseURL: "https://board.example", client: &nativeResolveClient{call: func(_ context.Context, method, path string, query url.Values, body any) (json.RawMessage, error) {
				calls++
				if method != http.MethodPost || path != "hosts/fixture-host/wake-intents/worker-native/resolve" || len(query) != 0 || body != callback {
					t.Fatal("notice rewrote exact callback or followed source URI")
				}
				return nativeJSON(t, response), nil
			}}}
			result, err := api.ResolveNativeNotice(context.Background(), binding, manifest, nativeJSON(t, notice))
			if err != nil || result.Actionable != actionable || calls != 1 {
				t.Fatalf("canonical source gate not called: %#v %v %d", result, err, calls)
			}
			if !actionable && result.Source != nil {
				t.Fatal("denied notice exposed source material")
			}
		})
	}
}
func TestNativeNoticeRejectsConfusionWithoutNetwork(t *testing.T) {
	m := nativeFixture()
	binding, _, notice := nativeNoticeFixture(m)
	raw := string(nativeJSON(t, notice))
	for i, bad := range []string{
		`{}`, raw + `{}`, raw + strings.Repeat(" ", 4097), strings.Replace(raw, `"dispatchGeneration":7`, `"dispatchGeneration":0`, 1),
		strings.Replace(raw, `"dispatchGeneration":7`, `"dispatchGeneration":9007199254740992`, 1),
		strings.Replace(raw, `"dispatchGeneration":7`, `"dispatchGeneration":7,"dispatchGeneration":7`, 1),
		strings.Replace(raw, `"source":`, `"extra":true,"source":`, 1),
		strings.Replace(raw, `"agentboard_wake_attempt"`, `"board_message"`, 1),
		strings.Replace(raw, `https://board.example/`, `https://foreign.example/`, 1),
		strings.Replace(raw, `/resolve"`, `/resolve?latest=true"`, 1),
		strings.Replace(raw, `"session_id":"fixture-session"`, `"session_id":"replacement"`, 1),
		strings.Replace(raw, `"bindingEpoch":3`, `"bindingEpoch":4`, 1),
		strings.Replace(raw, `"threadId":"11111111-1111-4111-8111-111111111111"`, `"threadId":"99999999-9999-4999-8999-999999999999"`, 1),
		strings.Replace(raw, `"persistent":true`, `"persistent":null`, 1),
		strings.Replace(raw, `"repo":"fixture/repo"`, `"repo":"foreign/repo"`, 1),
		strings.Replace(raw, `"enrollment_revision":1791750000000000`, `"enrollment_revision":1791750000000001`, 1),
		strings.Replace(raw, `"intent_id":`, `"intent_id":null,"intent_id":`, 1),
	} {
		calls := 0
		api := &API{agent: m.WorkerID, host: m.HostID, receipt: true, baseURL: "https://board.example", client: &nativeResolveClient{call: func(context.Context, string, string, url.Values, any) (json.RawMessage, error) {
			calls++
			return nil, nil
		}}}
		if _, err := api.ResolveNativeNotice(context.Background(), binding, m, []byte(bad)); err == nil || calls != 0 {
			t.Fatalf("malformed notice %d touched network", i)
		}
	}
	for _, baseURL := range []string{"http://board.example", "https://board.example/", "https://board.example/path", "https://board.example?x=1", "https://user@board.example"} {
		api := &API{agent: m.WorkerID, host: m.HostID, receipt: true, baseURL: baseURL, client: &nativeResolveClient{call: func(context.Context, string, string, url.Values, any) (json.RawMessage, error) {
			t.Fatal("invalid configured origin fetched")
			return nil, nil
		}}}
		if _, err := api.ResolveNativeNotice(context.Background(), binding, m, []byte(raw)); err == nil {
			t.Fatal("invalid origin accepted")
		}
	}
	api := &API{agent: m.WorkerID, host: m.HostID, receipt: false, baseURL: "https://board.example"}
	if _, err := api.ResolveNativeNotice(context.Background(), binding, m, []byte(raw)); err == nil {
		t.Fatal("host scope accepted for receiving callback")
	}
}

func TestNativeURIComponentMatchesMapping(t *testing.T) {
	const input = "host :/@+$,;=&?#[]-_.!~*'()"
	const want = "host%20%3A%2F%40%2B%24%2C%3B%3D%26%3F%23%5B%5D-_.!~*'()"
	if got := nativeURIComponent(input); got != want {
		t.Fatalf("encodeURIComponent drift: %s", got)
	}
}

func TestNativeManifestBindingTextMatchesFrozenCallbackBound(t *testing.T) {
	for _, field := range []string{"host", "session", "pane"} {
		for _, length := range []int{240, 241} {
			m := nativeFixture()
			text := strings.Repeat("x", length)
			switch field {
			case "host":
				m.HostID = text
			case "session":
				m.SessionID = text
			case "pane":
				m.PaneID = text
			}
			if (m.Validate() == nil) != (length == 240) {
				t.Fatalf("%s text length %d diverges from callback", field, length)
			}
		}
	}
}

func TestNativeAuthorityTransitTimeAndCancelledFreshResponse(t *testing.T) {
	m := nativeFixture()
	s := nativeSnapshotFixture(m)
	api := &API{agent: m.WorkerID, host: m.HostID, client: &nativeTestClient{call: func(context.Context, string, string, url.Values, any) (json.RawMessage, error) {
		time.Sleep(35 * time.Millisecond)
		return nativeJSON(t, s), nil
	}}}
	fetched, err := api.FetchNativeAuthority(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	approval, err := BuildNativeApproval(m, fetched, fetched.RequestStarted())
	if err != nil {
		t.Fatal(err)
	}
	if time.Until(approval.Deadline) >= NativeAuthorityLifetime-30*time.Millisecond {
		t.Fatal("transit time extended approval")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Millisecond)
	defer cancel()
	api.client = &nativeTestClient{call: func(ctx context.Context, _ string, _ string, _ url.Values, _ any) (json.RawMessage, error) {
		<-ctx.Done()
		// A successful-looking response arriving after cancellation cannot revive
		// the request's authority, even when its advertised TTL remains 5000.
		return nativeJSON(t, s), nil
	}}
	if _, err := api.FetchNativeAuthority(ctx); err == nil {
		t.Fatal("cancelled response minted fresh approval")
	}
}
