//go:build !linux

package owner

import (
	"errors"
	"net"
	"os"
)

// Darwin LOCAL_PEERPID is available, but PID alone is insufficient. A verified
// libproc/audit-token lifetime AND running executable identity implementation is
// required before supporting Darwin. Do not silently accept socket path or PID.
func platformReady() error {
	return errors.New("native owner connected-peer/process/build proof unsupported on this platform")
}
func InspectProcess(int) (ProcessIdentity, error) { return ProcessIdentity{}, platformReady() }
func verifyPeer(*net.UnixConn, bool) (ProcessIdentity, os.FileInfo, error) {
	return ProcessIdentity{}, nil, platformReady()
}
