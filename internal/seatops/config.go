package seatops

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Config is the optional host-local seat operations file. Every field has a
// working default, so a missing file means "all named Herdr seats".
type Config struct {
	Version int `json:"version"`
	// Allow, when non-empty, limits nudges and reaps to these agent IDs.
	Allow []string `json:"allow,omitempty"`
	// Deny never nudges or reaps these agent IDs or Herdr workspace IDs.
	Deny []string `json:"deny,omitempty"`
	// MinGap is the minimum time between two nudges of one seat.
	MinGap Duration `json:"min_gap,omitempty"`
	// IdleAfter is how long a seat idles with open work before a keep-going nudge.
	IdleAfter Duration `json:"idle_after,omitempty"`
	// ReapAfter is how long a finished seat idles before its pane is closed.
	ReapAfter Duration `json:"reap_after,omitempty"`
	// TreehouseRoots are explicit v3 pool roots whose leases reap may return.
	TreehouseRoots []string `json:"treehouse_roots,omitempty"`
	StateFile      string   `json:"state_file,omitempty"`
	KillSwitch     string   `json:"kill_switch,omitempty"`
}

// Duration decodes Go duration strings such as "15m".
type Duration struct{ time.Duration }

func (d *Duration) UnmarshalJSON(raw []byte) error {
	var text string
	if err := json.Unmarshal(raw, &text); err != nil {
		return errors.New("durations are strings such as \"15m\"")
	}
	value, err := time.ParseDuration(text)
	if err != nil || value <= 0 {
		return fmt.Errorf("invalid duration %q", text)
	}
	d.Duration = value
	return nil
}

func (d Duration) MarshalJSON() ([]byte, error) { return json.Marshal(d.String()) }

// DefaultConfigPath is ~/.config/agentboard/seat/config.json.
func DefaultConfigPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "agentboard", "seat", "config.json")
}

// LoadConfig reads path, or returns defaults when path does not exist. The file
// decides who gets prompted, so it must be owned by this user and not writable
// by group or others.
func LoadConfig(path string) (Config, error) {
	cfg := Config{Version: 1}
	raw, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return cfg, err
	default:
		info, err := os.Stat(path)
		if err != nil {
			return cfg, err
		}
		if info.Mode().Perm()&0o022 != 0 {
			return cfg, fmt.Errorf("%s must not be group/world writable", path)
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Getuid() {
			return cfg, fmt.Errorf("%s must be owned by the current user", path)
		}
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&cfg); err != nil {
			return cfg, fmt.Errorf("%s: %w", path, err)
		}
		if cfg.Version != 1 {
			return cfg, fmt.Errorf("%s: unsupported version %d", path, cfg.Version)
		}
	}
	home, _ := os.UserHomeDir()
	if cfg.MinGap.Duration == 0 {
		cfg.MinGap.Duration = 15 * time.Minute
	}
	if cfg.IdleAfter.Duration == 0 {
		cfg.IdleAfter.Duration = 20 * time.Minute
	}
	if cfg.ReapAfter.Duration == 0 {
		cfg.ReapAfter.Duration = 30 * time.Minute
	}
	if cfg.StateFile == "" {
		cfg.StateFile = filepath.Join(home, ".local", "state", "agentboard", "seat-ops.json")
	}
	if cfg.KillSwitch == "" {
		cfg.KillSwitch = filepath.Join(home, ".config", "agentboard", "seat", "off")
	}
	cfg.StateFile, cfg.KillSwitch = expandHome(cfg.StateFile, home), expandHome(cfg.KillSwitch, home)
	for i, root := range cfg.TreehouseRoots {
		cfg.TreehouseRoots[i] = expandHome(root, home)
		if !filepath.IsAbs(cfg.TreehouseRoots[i]) {
			return cfg, fmt.Errorf("treehouse root %q must be absolute", root)
		}
	}
	return cfg, nil
}

func expandHome(path, home string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		return filepath.Join(home, strings.TrimPrefix(path, "~"))
	}
	return path
}

// excluded reports why a seat is outside this host's scope, or "".
func (c Config) excluded(agentID, workspace string) string {
	for _, token := range c.Deny {
		if token == agentID || token == workspace {
			return "denylist"
		}
	}
	if len(c.Allow) == 0 {
		return ""
	}
	for _, id := range c.Allow {
		if id == agentID {
			return ""
		}
	}
	return "not allowlisted"
}
