// Package worker connects supervised host bindings to the scoped Phoenix API.
package worker

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/agentboard/internal/config"
)

const Protocol = 1
const AdapterVersion = "pi-native-v1"
const ClaudeAdapterVersion = "claude-hook-v1"
const MaxFrameBytes = 16 << 10

type Binding struct {
	Agent      string `json:"agent_id"`
	Model      string `json:"model"`
	Harness    string `json:"harness"`
	Host       string `json:"host_id"`
	Server     string `json:"server_id"`
	Session    string `json:"session_id"`
	Generation string `json:"adapter_generation"`
	Adapter    string `json:"adapter"`
	Socket     string `json:"socket_path"`
	TokenFile  string `json:"token_file"`
	Epoch      int64  `json:"binding_epoch"`
}

type Config struct {
	Version    int       `json:"version"`
	URL        string    `json:"url"`
	CAFile     string    `json:"ca_file,omitempty"`
	JournalDir string    `json:"journal_dir"`
	Bindings   []Binding `json:"bindings"`
}

func Load(path string) (Config, error) {
	var cfg Config
	data, err := ReadProtected(path, 1<<20)
	if err != nil {
		return cfg, err
	}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if dec.Decode(&cfg) != nil {
		return cfg, errors.New("invalid worker configuration")
	}
	var trailing any
	if dec.Decode(&trailing) != io.EOF {
		return cfg, errors.New("invalid worker configuration suffix")
	}
	if cfg.Version != Protocol || !filepath.IsAbs(cfg.JournalDir) || len(cfg.Bindings) == 0 || len(cfg.Bindings) > 64 {
		return cfg, errors.New("unsupported worker config version, journal directory or binding count")
	}
	seen := map[string]bool{}
	for _, b := range cfg.Bindings {
		if !config.ValidID(b.Agent) || b.Host == "" || b.Server == "" || b.Session == "" || b.Generation == "" || b.Model == "" || b.Harness == "" || b.Epoch < 0 || !filepath.IsAbs(b.Socket) || !filepath.IsAbs(b.TokenFile) || seen[b.Agent] {
			return cfg, errors.New("invalid or duplicate worker binding")
		}
		if b.Adapter != AdapterVersion && b.Adapter != ClaudeAdapterVersion && b.Adapter != "manual" && b.Adapter != "herdr" {
			return cfg, errors.New("unknown worker adapter")
		}
		if b.Adapter == ClaudeAdapterVersion && b.Harness != "claude" {
			return cfg, errors.New("Claude native adapter requires Claude harness attribution")
		}
		seen[b.Agent] = true
	}
	return cfg, nil
}

// ReadProtected refuses links, non-regular files, other owners and group/world access.
func ReadProtected(path string, limit int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || !owned(info) {
		return nil, errors.New("protected file unavailable or permissions/owner invalid")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, errors.New("protected file unavailable")
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return nil, errors.New("protected file changed during open")
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("protected file exceeds limit or cannot be read")
	}
	return data, nil
}

func PrivateDir(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("private directory must be absolute")
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return errors.New("cannot create private directory")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 || !owned(info) {
		return errors.New("private directory permissions/owner invalid")
	}
	return nil
}

// WriteProtected publishes a file durably without following an existing link.
func WriteProtected(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return writeBytes(path, append(data, '\n'))
}

func writeBytes(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := PrivateDir(dir); err != nil {
		return err
	}
	if info, err := os.Lstat(path); err == nil {
		if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || !owned(info) {
			return errors.New("refusing foreign or unprotected output")
		}
	} else if !os.IsNotExist(err) {
		return errors.New("cannot inspect protected output")
	}
	return atomicBytes(path, data)
}

// atomicBytes fsyncs both contents and the renamed directory entry.
// Its caller validates destination directory and existing-file custody.
func atomicBytes(path string, data []byte) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, ".worker-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func SaveCapability(path, token string) error { return writeBytes(path, []byte(token+"\n")) }
