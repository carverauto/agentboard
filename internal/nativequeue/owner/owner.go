// Package owner provides explicitly approved, connect-only native peer custody.
// It is not registered with worker run, installation, admission, or enrollment.
package owner

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

var errUnverified = errors.New("native owner evidence unavailable or retired")
var token = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
var digest = regexp.MustCompile(`^[a-f0-9]{64}$`)
var uuid = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

const maxSafe = 9007199254740991

// ProcessIdentity is kernel-derived inventory, not permission or a thread epoch.
type ProcessIdentity struct {
	PID              int    `json:"pid"`
	UID              uint32 `json:"uid"`
	BootID           string `json:"bootId"`
	StartTicks       uint64 `json:"startTicks"`
	ExecutableSHA256 string `json:"executableSha256"`
}
type Endpoint struct {
	ServerID        string `json:"serverId"`
	EndpointID      string `json:"endpointId"`
	Generation      string `json:"generation"`
	Profile         string `json:"profile"`
	NativeVersion   string `json:"nativeVersion"`
	ProtocolSource  string `json:"protocolSource"`
	SchemaSHA256    string `json:"schemaSha256"`
	ExperimentalAPI bool   `json:"experimentalApi"`
	QueueAPI        bool   `json:"queueApi"`
}
type Recipient struct {
	ThreadID           string `json:"threadId"`
	IdentityKind       string `json:"identityKind"`
	EnrollmentRevision int64  `json:"enrollmentRevision"`
	BindingEpoch       int64  `json:"bindingEpoch"`
	Persistent         bool   `json:"persistent"`
	TopLevel           bool   `json:"topLevel"`
}
type Identity struct {
	Endpoint  Endpoint  `json:"endpoint"`
	Recipient Recipient `json:"recipient"`
}

// Approval must come from the runtime owner's independently approved manifest and
// current server authority. This package does not approve schemas, mint grants,
// fetch credentials, or turn fixture metadata into production authorization.
// Generation is calculated from the verified peer; the caller must leave it empty.
type Approval struct {
	ID                 string
	AuthorityRevision  int64
	Identity           Identity
	Peer               ProcessIdentity
	InitializeApproved bool
	Deadline           time.Time
}
type stamp struct {
	Dev string `json:"dev"`
	Ino string `json:"ino"`
}

func fileStamp(f os.FileInfo) (stamp, error) {
	s, ok := f.Sys().(*syscall.Stat_t)
	if !ok {
		return stamp{}, errUnverified
	}
	return stamp{fmt.Sprint(s.Dev), fmt.Sprint(s.Ino)}, nil
}
func valid(a Approval) bool {
	e, r := a.Identity.Endpoint, a.Identity.Recipient
	return token.MatchString(a.ID) && a.AuthorityRevision > 0 && a.AuthorityRevision <= maxSafe && a.InitializeApproved &&
		time.Until(a.Deadline) > 0 && time.Until(a.Deadline) <= 30*time.Second && e.Generation == "" && token.MatchString(e.ServerID) && token.MatchString(e.EndpointID) &&
		e.Profile == "codex-durable-advisory-v1" && e.NativeVersion == "0.162.0" && e.ProtocolSource == "rust-v0.162.0" && digest.MatchString(e.SchemaSHA256) && e.ExperimentalAPI && e.QueueAPI &&
		uuid.MatchString(r.ThreadID) && r.IdentityKind == "durable-conversation-v1" && r.EnrollmentRevision > 0 && r.EnrollmentRevision <= maxSafe && r.BindingEpoch > 0 && r.BindingEpoch <= maxSafe && r.Persistent && r.TopLevel &&
		a.Peer.PID > 0 && a.Peer.UID == uint32(os.Geteuid()) && a.Peer.BootID != "" && a.Peer.StartTicks > 0 && digest.MatchString(a.Peer.ExecutableSHA256)
}

// Owner holds one already-connected socket. Its stream is never read here.
// Retire shuts down only this connection, including the child's duplicate FD.
// It cannot undo a queued notice or synchronously observe a remote revocation.
type Owner struct {
	mu                    sync.Mutex
	conn                  *net.UnixConn
	approval              Approval
	expires               time.Time
	path                  string
	pathStamp             stamp
	socketStamp           stamp
	executable            os.FileInfo
	started, retired      bool
	controlOut, controlIn *os.File
	done                  chan struct{}
}

// Dial validates approval before any connection; pathname is an explicitly
// approved physical address (not discovery). No fallback, repair, or reconnect.
func Dial(ctx context.Context, pathname string, approval Approval) (*Owner, error) {
	started := time.Now()
	remaining := approval.Deadline.Sub(started)
	if !valid(approval) || remaining <= 0 || remaining > 30*time.Second {
		return nil, errUnverified
	}
	if err := platformReady(); err != nil {
		return nil, err
	}
	// Convert even a deserialized wall-clock deadline to one local monotonic
	// deadline before dialing. Clock changes never extend this owner lifetime.
	expires := started.Add(remaining)
	before, err := checkPath(pathname)
	if err != nil {
		return nil, errUnverified
	}
	c, err := (&net.Dialer{Timeout: 5 * time.Second, Deadline: expires}).DialContext(ctx, "unix", pathname)
	if err != nil {
		return nil, errUnverified
	}
	conn, ok := c.(*net.UnixConn)
	if !ok {
		c.Close()
		return nil, errUnverified
	}
	o := &Owner{conn: conn, approval: approval, expires: expires, path: pathname, pathStamp: before, done: make(chan struct{})}
	peer, executable, err := verifyPeer(conn, true)
	if err != nil || peer != approval.Peer {
		conn.Close()
		return nil, errUnverified
	}
	o.executable = executable
	body, _ := json.Marshal(peer)
	generation := sha256.Sum256(body)
	o.approval.Identity.Endpoint.Generation = "process:" + hex.EncodeToString(generation[:])
	f, err := conn.File()
	if err != nil {
		conn.Close()
		return nil, errUnverified
	}
	info, err := f.Stat()
	f.Close()
	if err != nil {
		conn.Close()
		return nil, errUnverified
	}
	o.socketStamp, err = fileStamp(info)
	if err != nil || o.check() != nil {
		o.Retire()
		return nil, errUnverified
	}
	go func() {
		select {
		case <-ctx.Done():
			o.Retire()
		case <-o.done:
		}
	}()
	go func() {
		timer := time.NewTimer(time.Until(expires))
		defer timer.Stop()
		select {
		case <-timer.C:
			o.Retire()
		case <-o.done:
		}
	}()
	return o, nil
}

func checkPath(pathname string) (stamp, error) {
	if !filepath.IsAbs(pathname) || filepath.Clean(pathname) != pathname || strings.ContainsAny(pathname, "\x00\r\n") {
		return stamp{}, errUnverified
	}
	for p := filepath.Dir(pathname); ; p = filepath.Dir(p) {
		s, err := os.Lstat(p)
		if err != nil || !s.IsDir() || s.Mode()&os.ModeSymlink != 0 {
			return stamp{}, errUnverified
		}
		st, ok := s.Sys().(*syscall.Stat_t)
		if !ok || (st.Uid != 0 && st.Uid != uint32(os.Geteuid())) || (s.Mode().Perm()&0022 != 0 && s.Mode()&os.ModeSticky == 0) {
			return stamp{}, errUnverified
		}
		if p == filepath.Dir(p) {
			break
		}
	}
	s, err := os.Lstat(pathname)
	if err != nil || s.Mode()&os.ModeSocket == 0 || s.Mode().Perm() != 0600 || s.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return stamp{}, errUnverified
	}
	st, ok := s.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != uint32(os.Geteuid()) || st.Nlink != 1 {
		return stamp{}, errUnverified
	}
	return fileStamp(s)
}
func (o *Owner) check() error {
	if o.retired || !time.Now().Before(o.expires) {
		return errUnverified
	}
	s, err := checkPath(o.path)
	if err != nil || s != o.pathStamp {
		return errUnverified
	}
	peer, executable, err := verifyPeer(o.conn, false)
	expected := o.approval.Peer
	peer.ExecutableSHA256 = expected.ExecutableSHA256
	if err != nil || peer != expected || executable == nil || !os.SameFile(executable, o.executable) || executable.Size() != o.executable.Size() || !executable.ModTime().Equal(o.executable.ModTime()) {
		return errUnverified
	}
	return nil
}

// Start gives a trusted child exactly FD 3 (native socket), FD 4 (owner replies),
// FD 5 (owner challenges). Only this library writes the owner attestation pipe.
// The caller selects a trusted, reviewed Node program, not a native process.
// Start never waits for that child; the caller owns cmd.Wait and result handling.
func (o *Owner) Start(cmd *exec.Cmd) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if cmd == nil || !filepath.IsAbs(cmd.Path) || !safeEnvironment(cmd.Env) || len(cmd.ExtraFiles) != 0 || o.started || o.check() != nil {
		return errUnverified
	}
	socket, err := o.conn.File()
	if err != nil {
		return errUnverified
	}
	defer socket.Close()
	childRead, ownerWrite, err := os.Pipe()
	if err != nil {
		return err
	}
	defer childRead.Close()
	ownerRead, childWrite, err := os.Pipe()
	if err != nil {
		ownerWrite.Close()
		return err
	}
	defer childWrite.Close()
	cmd.ExtraFiles = []*os.File{socket, childRead, childWrite}
	if err = cmd.Start(); err != nil {
		ownerWrite.Close()
		ownerRead.Close()
		return err
	}
	o.started = true
	o.controlOut = ownerWrite
	o.controlIn = ownerRead
	go o.serve()
	return nil
}

// FD-bearing Node children get no ambient credentials or preload/search-path hooks.
func safeEnvironment(env []string) bool {
	if env == nil {
		return false
	}
	allowed := map[string]bool{"PATH": true, "LANG": true, "LC_ALL": true, "TZ": true, "WS_NO_BUFFER_UTIL": true, "WS_NO_UTF_8_VALIDATE": true}
	seen := map[string]bool{}
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if !ok || !allowed[key] || seen[key] || strings.ContainsRune(value, 0) {
			return false
		}
		if (key == "WS_NO_BUFFER_UTIL" || key == "WS_NO_UTF_8_VALIDATE") && value != "1" {
			return false
		}
		seen[key] = true
	}
	return seen["WS_NO_BUFFER_UTIL"] && seen["WS_NO_UTF_8_VALIDATE"]
}
func (o *Owner) serve() {
	defer o.Retire()
	scanner := bufio.NewScanner(o.controlIn)
	scanner.Buffer(make([]byte, 256), 1024)
	var last uint64
	for scanner.Scan() {
		var request struct {
			Type      string `json:"type"`
			Challenge uint64 `json:"challenge"`
		}
		dec := json.NewDecoder(strings.NewReader(scanner.Text()))
		dec.DisallowUnknownFields()
		if dec.Decode(&request) != nil || request.Type != "attest" || request.Challenge != last+1 || request.Challenge > 1024 {
			return
		}
		var suffix any
		if dec.Decode(&suffix) != io.EOF {
			return
		}
		last = request.Challenge
		o.mu.Lock()
		if o.check() != nil {
			o.mu.Unlock()
			return
		}
		remaining := time.Until(o.expires).Milliseconds()
		if remaining > 250 {
			remaining = 250
		}
		if remaining < 1 {
			o.mu.Unlock()
			return
		}
		response := struct {
			Type              string   `json:"type"`
			Challenge         uint64   `json:"challenge"`
			ValidForMS        int64    `json:"validForMs"`
			ApprovalID        string   `json:"approvalId"`
			AuthorityRevision int64    `json:"authorityRevision"`
			Identity          Identity `json:"identity"`
			Socket            stamp    `json:"socket"`
		}{"attestation", last, remaining, o.approval.ID, o.approval.AuthorityRevision, o.approval.Identity, o.socketStamp}
		bytes, err := json.Marshal(response)
		out := o.controlOut
		o.mu.Unlock()
		if err != nil {
			return
		}
		if _, err = out.Write(append(bytes, '\n')); err != nil {
			return
		}
	}
}

// Retire is idempotent. Shutdown affects duplicates; Close alone would not.
func (o *Owner) Retire() {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.retired {
		return
	}
	o.retired = true
	close(o.done)
	if raw, err := o.conn.SyscallConn(); err == nil {
		_ = raw.Control(func(fd uintptr) { _ = syscall.Shutdown(int(fd), syscall.SHUT_RDWR) })
	}
	_ = o.conn.Close()
	if o.controlOut != nil {
		_ = o.controlOut.Close()
	}
	if o.controlIn != nil {
		_ = o.controlIn.Close()
	}
}
