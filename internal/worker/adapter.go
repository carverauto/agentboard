package worker

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

type Capability struct {
	Supported bool   `json:"supported"`
	Reason    string `json:"reason"`
}
type Probe struct {
	Protocol     int                   `json:"protocol"`
	Version      string                `json:"adapter_version"`
	Session      string                `json:"session_id"`
	Generation   string                `json:"generation"`
	State        string                `json:"state"`
	Reason       string                `json:"reason"`
	Capabilities map[string]Capability `json:"capabilities"`
	Outcome      string                `json:"outcome,omitempty"`
}

func AdapterCall(ctx context.Context, b Binding, action string, batch *Batch) (Probe, error) {
	var p Probe
	if b.Adapter != AdapterVersion {
		return p, errors.New("automatic adapter unsupported; use explicit check-in")
	}
	if err := PrivateDir(filepath.Dir(b.Socket)); err != nil {
		return p, err
	}
	info, err := os.Lstat(b.Socket)
	if err != nil || info.Mode()&os.ModeSocket == 0 || !owned(info) || info.Mode().Perm()&0077 != 0 {
		return p, errors.New("native socket unavailable, foreign or unprotected")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", b.Socket)
	if err != nil {
		return p, errors.New("native adapter disconnected")
	}
	defer conn.Close()
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	request := map[string]any{"protocol": Protocol, "action": action, "session_id": b.Session, "generation": b.Generation}
	if batch != nil {
		request["batch"] = batch
	}
	if json.NewEncoder(conn).Encode(request) != nil {
		return p, errors.New("native submission outcome uncertain")
	}
	if json.NewDecoder(io.LimitReader(conn, 64<<10)).Decode(&p) != nil {
		return p, errors.New("native submission outcome uncertain")
	}
	if p.Protocol != Protocol || p.Version != AdapterVersion || p.Session != b.Session || p.Generation != b.Generation {
		return p, errors.New("native identity changed; verified rebind required")
	}
	return p, nil
}

func VerifyAdapter(ctx context.Context, b Binding) (Probe, error) {
	p, err := AdapterCall(ctx, b, "inspect", nil)
	if err != nil {
		return p, err
	}
	for _, name := range []string{"idle_wake", "turn_start", "tool_return", "receipt", "recovery"} {
		cap, ok := p.Capabilities[name]
		if !ok || cap.Reason == "" {
			return p, errors.New("native adapter lacks capability proof")
		}
	}
	if !p.Capabilities["idle_wake"].Supported && !p.Capabilities["turn_start"].Supported && !p.Capabilities["tool_return"].Supported {
		return p, errors.New("automatic native boundary unsupported by this session profile")
	}
	return p, nil
}
