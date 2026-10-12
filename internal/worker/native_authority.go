package worker

// This is a callable, connect-free authority boundary. No worker/host loop calls
// it, and the server's durable native profile is default-off.
import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/carverauto/agentboard/internal/config"
	"github.com/carverauto/agentboard/internal/nativequeue/owner"
)

const NativeAuthorityContract = 1
const NativeAuthorityLifetime = 5 * time.Second
const NativeAuthorityPollInterval = time.Second
const MaxNativeAuthorityBytes = 32 << 10
const nativeSafeInteger = int64(9007199254740991)

var nativeToken = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
var nativeUUID = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)
var nativeDigest = regexp.MustCompile(`^[a-f0-9]{64}$`)
var errNativeAuthority = errors.New("native authority unavailable, malformed, changed or expired")

// NativeManifest contains only independently reviewed immutable inventory. It
// never supplies a native generation or proves permission by itself.
type NativeManifest struct {
	ManifestVersion    int                   `json:"manifest_version"`
	ID                 string                `json:"id"`
	WorkerID           string                `json:"worker_id"`
	HostID             string                `json:"host_id"`
	EnrollmentRevision int64                 `json:"enrollment_revision"`
	BindingEpoch       int64                 `json:"binding_epoch"`
	SessionID          string                `json:"session_id"`
	PaneID             string                `json:"pane_id"`
	SocketPath         string                `json:"socket_path"`
	InitializeApproved bool                  `json:"initialize_approved"`
	Endpoint           owner.Endpoint        `json:"endpoint"`
	Recipient          owner.Recipient       `json:"recipient"`
	Peer               owner.ProcessIdentity `json:"peer"`
}

func nativeASCII(s string, max int) bool {
	if len(s) == 0 || len(s) > max {
		return false
	}
	for _, c := range []byte(s) {
		if c < 32 || c > 126 {
			return false
		}
	}
	return true
}
func nativePositive(n int64) bool    { return n > 0 && n <= nativeSafeInteger }
func nativeNonnegative(n int64) bool { return n >= 0 && n <= nativeSafeInteger }
func nativePath(s string) bool {
	if !nativeASCII(s, 4096) || !filepath.IsAbs(s) || s == "/" || filepath.Clean(s) != s {
		return false
	}
	for _, part := range strings.Split(s[1:], "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}
func (m NativeManifest) Validate() error {
	e, r, p := m.Endpoint, m.Recipient, m.Peer
	if m.ManifestVersion != 1 || !nativeToken.MatchString(m.ID) || !config.ValidID(m.WorkerID) || !nativeASCII(m.HostID, 240) || !nativePositive(m.EnrollmentRevision) || !nativePositive(m.BindingEpoch) || !nativeASCII(m.SessionID, 240) || !nativeASCII(m.PaneID, 240) || !nativePath(m.SocketPath) || !m.InitializeApproved ||
		!nativeToken.MatchString(e.ServerID) || !nativeToken.MatchString(e.EndpointID) || e.Generation != "" || e.Profile != "codex-durable-advisory-v1" || e.NativeVersion != "0.162.0" || e.ProtocolSource != "rust-v0.162.0" || !nativeDigest.MatchString(e.SchemaSHA256) || !e.ExperimentalAPI || !e.QueueAPI ||
		!nativeUUID.MatchString(r.ThreadID) || r.IdentityKind != "durable-conversation-v1" || r.EnrollmentRevision != m.EnrollmentRevision || r.BindingEpoch != m.BindingEpoch || !r.Persistent || !r.TopLevel ||
		p.PID <= 0 || int64(p.PID) > 2147483647 || !nativeUUID.MatchString(p.BootID) || p.StartTicks == 0 || p.StartTicks > uint64(nativeSafeInteger) || !nativeDigest.MatchString(p.ExecutableSHA256) {
		return errNativeAuthority
	}
	return nil
}

// strictNativeJSON checks every object for duplicate keys, invalid UTF-8, null
// primitives and unsafe/non-integer JSON numbers before decoding into structs.
// Closed field sets are then checked at each schema level, with exact case.
func strictNativeJSON(raw []byte) (any, error) {
	if len(raw) == 0 || len(raw) > MaxNativeAuthorityBytes || !utf8.Valid(raw) || !json.Valid(raw) {
		return nil, errNativeAuthority
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var read func(int) (any, error)
	read = func(depth int) (any, error) {
		if depth > 8 {
			return nil, errNativeAuthority
		}
		t, err := d.Token()
		if err != nil {
			return nil, errNativeAuthority
		}
		if delimiter, ok := t.(json.Delim); ok {
			switch delimiter {
			case '{':
				object := map[string]any{}
				for d.More() {
					k, err := d.Token()
					key, ok := k.(string)
					if err != nil || !ok {
						return nil, errNativeAuthority
					}
					if _, exists := object[key]; exists {
						return nil, errNativeAuthority
					}
					value, err := read(depth + 1)
					if err != nil {
						return nil, err
					}
					object[key] = value
				}
				end, err := d.Token()
				if err != nil || end != json.Delim('}') {
					return nil, errNativeAuthority
				}
				return object, nil
			case '[':
				array := []any{}
				for d.More() {
					value, err := read(depth + 1)
					if err != nil {
						return nil, err
					}
					array = append(array, value)
					if len(array) > 64 {
						return nil, errNativeAuthority
					}
				}
				end, err := d.Token()
				if err != nil || end != json.Delim(']') {
					return nil, errNativeAuthority
				}
				return array, nil
			default:
				return nil, errNativeAuthority
			}
		}
		if number, ok := t.(json.Number); ok {
			n, err := strconv.ParseInt(string(number), 10, 64)
			if err != nil || n < 0 || n > nativeSafeInteger {
				return nil, errNativeAuthority
			}
		}
		if s, ok := t.(string); ok {
			for _, c := range s {
				if c > 126 || c < 32 {
					return nil, errNativeAuthority
				}
			}
		}
		return t, nil
	}
	value, err := read(0)
	if err != nil {
		return nil, err
	}
	if _, err = d.Token(); err != io.EOF {
		return nil, errNativeAuthority
	}
	return value, nil
}
func nativeObject(value any, keys ...string) (map[string]any, error) {
	object, ok := value.(map[string]any)
	if !ok || len(object) != len(keys) {
		return nil, errNativeAuthority
	}
	for _, key := range keys {
		if _, ok := object[key]; !ok {
			return nil, errNativeAuthority
		}
	}
	return object, nil
}
func nativeManifestObject(value any) error {
	object, err := nativeObject(value, "manifest_version", "id", "worker_id", "host_id", "enrollment_revision", "binding_epoch", "session_id", "pane_id", "socket_path", "initialize_approved", "endpoint", "recipient", "peer")
	if err != nil {
		return err
	}
	for _, v := range object {
		if v == nil {
			return errNativeAuthority
		}
	}
	for field, keys := range map[string][]string{
		"endpoint":  {"serverId", "endpointId", "generation", "profile", "nativeVersion", "protocolSource", "schemaSha256", "experimentalApi", "queueApi"},
		"recipient": {"threadId", "identityKind", "enrollmentRevision", "bindingEpoch", "persistent", "topLevel"},
		"peer":      {"pid", "uid", "bootId", "startTicks", "executableSha256"},
	} {
		nested, err := nativeObject(object[field], keys...)
		if err != nil {
			return err
		}
		for _, v := range nested {
			if v == nil {
				return errNativeAuthority
			}
		}
	}
	return nil
}

func ParseNativeManifest(raw []byte) (NativeManifest, error) {
	var m NativeManifest
	value, err := strictNativeJSON(raw)
	if err != nil {
		return m, err
	}
	if err = nativeManifestObject(value); err != nil {
		return m, err
	}
	if json.Unmarshal(raw, &m) != nil {
		return m, errNativeAuthority
	}
	return m, m.Validate()
}

// ReadNativeManifest refuses every symlink path component and opens the final
// file nonblocking/O_NOFOLLOW. No socket, process or credentials are inspected.
func ReadNativeManifest(path string) (NativeManifest, error) {
	var zero NativeManifest
	absolute, err := filepath.Abs(path)
	if err != nil || path == "" {
		return zero, errNativeAuthority
	}
	for p := filepath.Dir(absolute); ; p = filepath.Dir(p) {
		info, err := os.Lstat(p)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return zero, errNativeAuthority
		}
		if p == filepath.Dir(p) {
			break
		}
	}
	fd, err := syscall.Open(absolute, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return zero, errNativeAuthority
	}
	f := os.NewFile(uintptr(fd), "native manifest")
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > MaxNativeAuthorityBytes {
		return zero, errNativeAuthority
	}
	raw, err := io.ReadAll(io.LimitReader(f, MaxNativeAuthorityBytes+1))
	if err != nil {
		return zero, errNativeAuthority
	}
	return ParseNativeManifest(raw)
}

// CanonicalNativeManifest is the cross-language digest contract: sorted keys
// recursively, compact UTF-8 JSON, literal printable ASCII (no HTML escaping).
func CanonicalNativeManifest(m NativeManifest) ([]byte, error) {
	if err := m.Validate(); err != nil {
		return nil, err
	}
	raw, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	value, err := strictNativeJSON(raw)
	if err != nil {
		return nil, err
	}
	return nativeCanonical(value)
}
func nativeCanonical(value any) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}
func NativeManifestSHA256(m NativeManifest) (string, error) {
	raw, err := CanonicalNativeManifest(m)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

// NativeAuthoritySnapshot is untrusted until received through FetchNativeAuthority.
// Copying or editing exported metadata cannot forge its private read proof.
type NativeAuthoritySnapshot struct {
	ProtocolRevision          int             `json:"protocol_revision"`
	AuthorityContractRevision int             `json:"authority_contract_revision"`
	WorkerID                  string          `json:"worker_id"`
	HostID                    string          `json:"host_id"`
	AuthorityRevision         int64           `json:"authority_revision"`
	ApprovalID                *string         `json:"approval_id"`
	ManifestSHA256            *string         `json:"manifest_sha256"`
	Manifest                  *NativeManifest `json:"manifest"`
	EnrollmentRevision        int64           `json:"enrollment_revision"`
	BindingEpoch              int64           `json:"binding_epoch"`
	Permitted                 bool            `json:"permitted"`
	ReasonCodes               []string        `json:"reason_codes"`
	ValidForMS                int64           `json:"valid_for_ms"`
	requestStarted            time.Time
	authenticatedHash         [32]byte
	authenticated             bool
}

func (s NativeAuthoritySnapshot) RequestStarted() time.Time { return s.requestStarted }
func (s NativeAuthoritySnapshot) Validate() error {
	if s.ProtocolRevision != Protocol || s.AuthorityContractRevision != NativeAuthorityContract || !config.ValidID(s.WorkerID) || !nativeASCII(s.HostID, 256) || !nativeNonnegative(s.AuthorityRevision) || !nativeNonnegative(s.EnrollmentRevision) || !nativeNonnegative(s.BindingEpoch) || s.ReasonCodes == nil || len(s.ReasonCodes) > 32 {
		return errNativeAuthority
	}
	seen := map[string]bool{}
	for _, reason := range s.ReasonCodes {
		if !nativeToken.MatchString(reason) || seen[reason] {
			return errNativeAuthority
		}
		seen[reason] = true
	}
	if s.Permitted {
		if s.ValidForMS != 5000 || len(s.ReasonCodes) != 0 || s.Manifest == nil {
			return errNativeAuthority
		}
	} else if s.ValidForMS != 0 || len(s.ReasonCodes) == 0 {
		return errNativeAuthority
	}
	if s.Manifest == nil {
		if s.ApprovalID != nil || s.ManifestSHA256 != nil {
			return errNativeAuthority
		}
		return nil
	}
	m := *s.Manifest
	hash, err := NativeManifestSHA256(m)
	if err != nil || s.ApprovalID == nil || s.ManifestSHA256 == nil || *s.ApprovalID != m.ID || *s.ManifestSHA256 != hash || !nativePositive(s.AuthorityRevision) || m.WorkerID != s.WorkerID || m.HostID != s.HostID {
		return errNativeAuthority
	}
	// Denials may preserve the old immutable approval after enrollment/rebind.
	if s.Permitted && (m.EnrollmentRevision != s.EnrollmentRevision || m.BindingEpoch != s.BindingEpoch) {
		return errNativeAuthority
	}
	return nil
}
func ParseNativeAuthoritySnapshot(raw []byte) (NativeAuthoritySnapshot, error) {
	var s NativeAuthoritySnapshot
	value, err := strictNativeJSON(raw)
	if err != nil {
		return s, err
	}
	object, err := nativeObject(value, "protocol_revision", "authority_contract_revision", "worker_id", "host_id", "authority_revision", "approval_id", "manifest_sha256", "manifest", "enrollment_revision", "binding_epoch", "permitted", "reason_codes", "valid_for_ms")
	if err != nil {
		return s, err
	}
	for k, v := range object {
		if v == nil && k != "approval_id" && k != "manifest_sha256" && k != "manifest" {
			return s, errNativeAuthority
		}
	}
	if object["manifest"] != nil {
		if err = nativeManifestObject(object["manifest"]); err != nil {
			return s, err
		}
	}
	if json.Unmarshal(raw, &s) != nil {
		return s, errNativeAuthority
	}
	return s, s.Validate()
}
func nativeSnapshotHash(s NativeAuthoritySnapshot) [32]byte {
	raw, _ := json.Marshal(s)
	return sha256.Sum256(raw)
}

// FetchNativeAuthority uses only the protected host bearer and exactly its
// authenticated host/worker route. Captures time before I/O; never retries.
func (a *API) FetchNativeAuthority(ctx context.Context) (NativeAuthoritySnapshot, error) {
	var s NativeAuthoritySnapshot
	if a == nil || a.client == nil || a.receipt || !config.ValidID(a.agent) || !nativeASCII(a.host, 256) {
		return s, errNativeAuthority
	}
	started := time.Now()
	bounded, cancel := context.WithDeadline(ctx, started.Add(NativeAuthorityLifetime))
	defer cancel()
	raw, err := a.client.JSONOnce(bounded, http.MethodGet, "hosts/"+url.PathEscape(a.host)+"/workers/"+url.PathEscape(a.agent)+"/native-authority", nil, nil)
	if err != nil {
		return s, errNativeAuthority
	}
	s, err = ParseNativeAuthoritySnapshot(raw)
	if err != nil || bounded.Err() != nil || s.WorkerID != a.agent || s.HostID != a.host || !time.Now().Before(started.Add(NativeAuthorityLifetime)) {
		return NativeAuthoritySnapshot{}, errNativeAuthority
	}
	s.requestStarted = started
	s.authenticated = true
	s.authenticatedHash = nativeSnapshotHash(s)
	return s, nil
}

// BuildNativeApproval never trusts a supplied wall timestamp. requestStarted
// must equal the original monotonic start captured by the authenticated read.
// Even an unchanged fresh snapshot cannot renew an already built Owner.
func BuildNativeApproval(expected NativeManifest, s NativeAuthoritySnapshot, requestStarted time.Time) (owner.Approval, error) {
	var zero owner.Approval
	deadline := requestStarted.Add(NativeAuthorityLifetime)
	if expected.Validate() != nil || expected.Peer.UID != uint32(os.Geteuid()) || s.Validate() != nil || !s.authenticated || s.authenticatedHash != nativeSnapshotHash(s) || requestStarted != s.requestStarted || requestStarted == requestStarted.Round(0) || !s.Permitted || s.Manifest == nil || *s.Manifest != expected || !time.Now().Before(deadline) {
		return zero, errNativeAuthority
	}
	return owner.Approval{ID: expected.ID, AuthorityRevision: s.AuthorityRevision, Identity: owner.Identity{Endpoint: expected.Endpoint, Recipient: expected.Recipient}, Peer: expected.Peer, InitializeApproved: expected.InitializeApproved, Deadline: deadline}, nil
}

// PollNativeAuthority is serial, bounded snapshot polling for one immutable
// owner. It never reconnects, replays, constructs another owner or refreshes the
// original deadline. Caller supplies owner.Retire; invoked on every exit.
// No production execution loop registers this function in this slice.
func (a *API) PollNativeAuthority(ctx context.Context, expected NativeManifest, initial NativeAuthoritySnapshot, retire func()) error {
	if retire == nil {
		return errNativeAuthority
	}
	defer retire()
	approval, err := BuildNativeApproval(expected, initial, initial.RequestStarted())
	if err != nil {
		return err
	}
	bounded, cancel := context.WithDeadline(ctx, approval.Deadline)
	defer cancel()
	timer := time.NewTimer(NativeAuthorityPollInterval)
	defer timer.Stop()
	for {
		select {
		case <-bounded.Done():
			return errNativeAuthority
		case <-timer.C:
		}
		snapshot, err := a.FetchNativeAuthority(bounded)
		if err != nil {
			return errNativeAuthority
		}
		next, err := BuildNativeApproval(expected, snapshot, snapshot.RequestStarted())
		if err != nil || next.AuthorityRevision != approval.AuthorityRevision || next.ID != approval.ID || next.Identity != approval.Identity || next.Peer != approval.Peer || !time.Now().Before(approval.Deadline) {
			return errNativeAuthority
		}
		// Schedule only after completion: at most one request can be outstanding.
		timer.Reset(NativeAuthorityPollInterval)
	}
}

// NativeAuthorityMutation is the bounded captain response. Its authority is
// informational only: a captain response is never a host read proof.
type NativeAuthorityMutation struct {
	ProtocolRevision          int                     `json:"protocol_revision"`
	AuthorityContractRevision int                     `json:"authority_contract_revision"`
	Authority                 NativeAuthoritySnapshot `json:"authority"`
	Idempotent                bool                    `json:"idempotent"`
}

func ParseNativeAuthorityMutation(raw []byte) (NativeAuthorityMutation, error) {
	var result NativeAuthorityMutation
	value, err := strictNativeJSON(raw)
	if err != nil {
		return result, err
	}
	object, err := nativeObject(value, "protocol_revision", "authority_contract_revision", "authority", "idempotent")
	if err != nil {
		return result, err
	}
	for _, v := range object {
		if v == nil {
			return result, errNativeAuthority
		}
	}
	if json.Unmarshal(raw, &result) != nil || result.ProtocolRevision != Protocol || result.AuthorityContractRevision != NativeAuthorityContract {
		return result, errNativeAuthority
	}
	authority, err := nativeCanonical(object["authority"])
	if err != nil {
		return result, err
	}
	result.Authority, err = ParseNativeAuthoritySnapshot(authority)
	return result, err
}

// ResolveNativeNotice is the receiving half of the advisory bridge. The exact
// frozen callback is sent to the existing authenticated source gate before any
// source can be returned. Its URI is checked as a pointer, never followed.
// This read-only call does not mark receipt, claim work or authorize execution.
func (a *API) ResolveNativeNotice(ctx context.Context, b Binding, manifest NativeManifest, raw []byte) (*WakeResolution, error) {
	if len(raw) > 4096 || a == nil || !a.receipt || a.agent != b.Agent || a.host != b.Host || manifest.Validate() != nil {
		return nil, errNativeAuthority
	}
	value, err := strictNativeJSON(raw)
	if err != nil {
		return nil, err
	}
	object, err := nativeObject(value, "attemptId", "source", "recipient", "bindingEpoch", "dispatchGeneration", "wakeCallback")
	if err != nil {
		return nil, err
	}
	source, err := nativeObject(object["source"], "kind", "id", "version", "uri")
	if err != nil {
		return nil, err
	}
	recipient, err := nativeObject(object["recipient"], "threadId", "identityKind", "enrollmentRevision", "bindingEpoch", "persistent", "topLevel")
	if err != nil {
		return nil, err
	}
	callback, err := nativeObject(object["wakeCallback"], "attempt_id", "intent_id", "reason_hash", "payload_hash", "recipient")
	if err != nil {
		return nil, err
	}
	legacy, err := nativeObject(callback["recipient"], "agent_id", "host_id", "repo", "enrollment_revision", "binding_epoch", "session_id", "adapter_generation")
	if err != nil {
		return nil, err
	}
	for _, fields := range []map[string]any{object, source, recipient, callback, legacy} {
		for _, v := range fields {
			if v == nil {
				return nil, errNativeAuthority
			}
		}
	}
	var notice struct {
		AttemptID string `json:"attemptId"`
		Source    struct {
			Kind    string `json:"kind"`
			ID      string `json:"id"`
			Version string `json:"version"`
			URI     string `json:"uri"`
		} `json:"source"`
		Recipient          owner.Recipient `json:"recipient"`
		BindingEpoch       int64           `json:"bindingEpoch"`
		DispatchGeneration int64           `json:"dispatchGeneration"`
		WakeCallback       WakeCallback    `json:"wakeCallback"`
	}
	if json.Unmarshal(raw, &notice) != nil {
		return nil, errNativeAuthority
	}
	frozen := notice.WakeCallback
	f := frozen.Recipient
	if frozen.ValidateBinding(b) != nil || !nativePositive(notice.DispatchGeneration) || notice.AttemptID != frozen.Attempt || notice.BindingEpoch != manifest.BindingEpoch || notice.Recipient != manifest.Recipient || notice.Source.Kind != "agentboard_wake_attempt" || notice.Source.ID != frozen.Attempt || notice.Source.Version != frozen.PayloadHash || f.Agent != manifest.WorkerID || f.Host != manifest.HostID || f.Enrollment != manifest.EnrollmentRevision || f.Epoch != manifest.BindingEpoch || f.Session != manifest.SessionID || f.Generation != manifest.PaneID {
		return nil, errNativeAuthority
	}
	origin, err := url.Parse(a.baseURL)
	if err != nil || origin.Scheme != "https" || origin.Hostname() == "" || origin.User != nil || origin.Path != "" || origin.RawQuery != "" || origin.Fragment != "" || origin.ForceQuery || origin.String() != a.baseURL {
		return nil, errNativeAuthority
	}
	expectedURI := a.baseURL + "/api/v1/hosts/" + nativeURIComponent(f.Host) + "/wake-intents/" + nativeURIComponent(f.Agent) + "/resolve"
	if notice.Source.URI != expectedURI {
		return nil, errNativeAuthority
	}
	return a.WakeResolve(ctx, b, frozen)
}

// Match JavaScript encodeURIComponent exactly for the bounded ASCII identity.
func nativeURIComponent(value string) string {
	const hex = "0123456789ABCDEF"
	var result strings.Builder
	for _, b := range []byte(value) {
		if b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || strings.ContainsRune("-_.!~*'()", rune(b)) {
			result.WriteByte(b)
		} else {
			result.WriteByte('%')
			result.WriteByte(hex[b>>4])
			result.WriteByte(hex[b&15])
		}
	}
	return result.String()
}
