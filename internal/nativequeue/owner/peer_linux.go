//go:build linux

package owner

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
)

func platformReady() error { return nil }

// InspectProcess inventories a process for owner review. It grants nothing.
func InspectProcess(pid int) (ProcessIdentity, error) {
	p, _, err := process(pid, true)
	return p, err
}
func verifyPeer(c *net.UnixConn, hash bool) (ProcessIdentity, os.FileInfo, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return ProcessIdentity{}, nil, err
	}
	var cred *syscall.Ucred
	var inner error
	if err = raw.Control(func(fd uintptr) {
		cred, inner = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil || inner != nil || cred == nil || cred.Uid != uint32(os.Geteuid()) {
		return ProcessIdentity{}, nil, errUnverified
	}
	p, info, err := process(int(cred.Pid), hash)
	if err != nil || p.UID != cred.Uid {
		return ProcessIdentity{}, nil, errUnverified
	}
	return p, info, nil
}
func statProcess(pid int) (ProcessIdentity, error) {
	if pid <= 0 {
		return ProcessIdentity{}, errUnverified
	}
	base := fmt.Sprintf("/proc/%d", pid)
	dir, err := os.Stat(base)
	if err != nil {
		return ProcessIdentity{}, errUnverified
	}
	st, ok := dir.Sys().(*syscall.Stat_t)
	if !ok {
		return ProcessIdentity{}, errUnverified
	}
	data, err := os.ReadFile(base + "/stat")
	if err != nil || len(data) > 16384 {
		return ProcessIdentity{}, errUnverified
	}
	// Linux comm can contain spaces and closing parentheses.
	end := strings.LastIndexByte(string(data), ')')
	if end < 0 {
		return ProcessIdentity{}, errUnverified
	}
	fields := strings.Fields(string(data[end+1:]))
	if len(fields) < 20 || fields[0] == "Z" || fields[0] == "X" {
		return ProcessIdentity{}, errUnverified
	}
	ticks, err := strconv.ParseUint(fields[19], 10, 64)
	if err != nil || ticks == 0 {
		return ProcessIdentity{}, errUnverified
	}
	boot, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil || len(boot) > 128 || !uuid.MatchString(strings.TrimSpace(string(boot))) {
		return ProcessIdentity{}, errUnverified
	}
	return ProcessIdentity{PID: pid, UID: st.Uid, BootID: strings.TrimSpace(string(boot)), StartTicks: ticks}, nil
}
func process(pid int, hash bool) (ProcessIdentity, os.FileInfo, error) {
	before, err := statProcess(pid)
	if err != nil {
		return ProcessIdentity{}, nil, err
	}
	file, err := os.Open(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		return ProcessIdentity{}, nil, errUnverified
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > 512<<20 {
		return ProcessIdentity{}, nil, errUnverified
	}
	var sum string
	if hash {
		h := sha256.New()
		n, err := io.Copy(h, io.LimitReader(file, (512<<20)+1))
		if err != nil || n != info.Size() {
			return ProcessIdentity{}, nil, errUnverified
		}
		sum = hex.EncodeToString(h.Sum(nil))
	}
	after, err := statProcess(pid)
	current, e := os.Stat(fmt.Sprintf("/proc/%d/exe", pid))
	held, e2 := file.Stat()
	if err != nil || e != nil || e2 != nil || before != after || !os.SameFile(info, current) || !os.SameFile(info, held) || info.Size() != held.Size() || !info.ModTime().Equal(held.ModTime()) {
		return ProcessIdentity{}, nil, errUnverified
	}
	before.ExecutableSHA256 = sum
	return before, info, nil
}
