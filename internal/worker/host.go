package worker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
)

// Host delivery is shadow-only until #150 supplies its shared native admission
// and the captain separately elects a wake owner. It never calls an adapter.
type WakeReference struct {
	ID          string `json:"intent_id"`
	Revision    int64  `json:"intent_revision"`
	Reason      string `json:"reason"`
	Hash        string `json:"reason_hash"`
	Agent       string `json:"recipient_id"`
	Repo        string `json:"repo"`
	Disposition string `json:"disposition"`
	Source      struct {
		Kind    string `json:"kind"`
		ID      string `json:"id"`
		Version string `json:"version"`
		Task    string `json:"task_id"`
	} `json:"source"`
	Reasons []string `json:"reason_codes"`
}

type WakeInspection struct {
	Mode      string          `json:"mode"`
	Native    bool            `json:"native_delivery_enabled"`
	Intents   []WakeReference `json:"intents"`
	Next      string          `json:"next_cursor"`
	Journal   string          `json:"journal_phase,omitempty"`
	Readiness struct {
		Host       string   `json:"host_id"`
		Agent      string   `json:"worker_id"`
		Epoch      int64    `json:"binding_epoch"`
		Session    string   `json:"session_id"`
		Generation string   `json:"adapter_generation"`
		Enrollment int64    `json:"enrollment_revision"`
		Reasons    []string `json:"reason_codes"`
	} `json:"readiness"`
}

var hostRepo = regexp.MustCompile(`^[a-z0-9_.-]+/[a-z0-9_.-]+$`)
var wakeUUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var wakeHash = regexp.MustCompile(`^[0-9a-f]{64}$`)

func ValidateHost(cfg Config) error {
	for _, b := range cfg.Bindings {
		if len(b.Repos) == 0 || len(b.Repos) > 20 {
			return errors.New("host binding requires explicit repository scopes")
		}
		for _, repo := range b.Repos {
			if !hostRepo.MatchString(repo) {
				return errors.New("host repository must be normalized owner/repo")
			}
		}
	}
	return nil
}

// InspectWake holds the same local custody lock as Step, and preserves crash
// journals. Only the scoped non-consuming wake page is read: state/report and
// adapter calls are intentionally absent, so host health is not model activity.
func InspectWake(ctx context.Context, cfg Config, b Binding, cursor string) (Report, error) {
	r := Report{Agent: b.Agent, State: "dry_run", Reason: "nudge_admission_unavailable (#150); native input and restart disabled"}
	if err := ValidateHost(cfg); err != nil {
		return r, err
	}
	if cursor != "" && !wakeUUID.MatchString(cursor) {
		return r, errors.New("wake cursor must be a UUID")
	}
	if err := PrivateDir(cfg.JournalDir); err != nil {
		return r, err
	}
	unlock, err := Lock(filepath.Join(cfg.JournalDir, b.Agent+".lock"))
	if err != nil {
		return r, err
	}
	defer unlock()
	j, err := LoadJournal(cfg, b)
	if err != nil {
		return r, err
	}
	a, err := OpenAPI(cfg, b, false)
	if err != nil {
		return r, err
	}
	defer a.Close()
	query := url.Values{"limit": {"32"}}
	if cursor != "" {
		query.Set("cursor", cursor)
	}
	raw, err := a.wakePage(ctx, b, query)
	if err != nil {
		return r, err
	}
	var page WakeInspection
	if json.Unmarshal(raw, &page) != nil || page.Mode != "dry_run" || page.Native || len(page.Intents) > 32 ||
		page.Readiness.Host != b.Host || page.Readiness.Agent != b.Agent || page.Readiness.Epoch != b.Epoch ||
		page.Readiness.Session != b.Session || page.Readiness.Generation != b.Generation || page.Readiness.Enrollment < 1 ||
		(page.Next != "" && !wakeUUID.MatchString(page.Next)) {
		return r, errors.New("host wake page or recipient fence invalid")
	}
	for _, ref := range page.Intents {
		if ref.Agent != b.Agent || !slices.Contains(b.Repos, ref.Repo) || !wakeUUID.MatchString(ref.ID) ||
			!wakeHash.MatchString(ref.Hash) || ref.Revision < 1 || len(ref.Source.ID) > 240 || len(ref.Source.Version) > 240 {
			return r, errors.New("wake source outside local identity/repository contract")
		}
	}
	if j != nil {
		page.Journal = j.Phase
	}
	r.Wake = &page
	return r, nil
}

// ServeHost shares the worker's cancellation/backoff/output loop. Each binding
// cycles bounded UUID pages from the start after exhaustion or process restart;
// this cursor is a shadow scan position, never a delivery or source watermark.
func ServeHost(ctx context.Context, cfg Config, out io.Writer) error {
	if err := ValidateHost(cfg); err != nil {
		return err
	}
	var cursors sync.Map
	inspect := func(ctx context.Context, cfg Config, b Binding) (Report, error) {
		cursor := ""
		if value, ok := cursors.Load(b.Agent); ok {
			cursor = value.(string)
		}
		r, err := InspectWake(ctx, cfg, b, cursor)
		if err == nil {
			cursors.Store(b.Agent, r.Wake.Next)
		}
		return r, err
	}
	return serveBindings(ctx, cfg, out, inspect, false)
}

type HostPlan struct {
	InstallPlan
	Contents map[string]string `json:"contents"`
}

// Preview only: it neither installs hooks/adapters nor writes files, provisions
// credentials, loads services, or modifies either host or worker manifests.
func HostSupervisionPreview(home, configPath, platform string) (HostPlan, error) {
	p := HostPlan{InstallPlan: InstallPlan{Apply: false, Preserved: "Foreign supervision/hooks, protected credentials and pending worker journals"}}
	if !filepath.IsAbs(home) || !filepath.IsAbs(configPath) || strings.ContainsAny(home+configPath, "\r\n\x00") {
		return p, errors.New("host preview requires absolute single-line local paths")
	}
	binary := filepath.Join(home, ".local", "bin", "agentboard")
	var path, body string
	switch platform {
	case "darwin":
		path = filepath.Join(home, "Library", "LaunchAgents", "dev.carverauto.agentboard.host.plist")
		body = fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>dev.carverauto.agentboard.host</string>
<key>ProgramArguments</key><array><string>%s</string><string>host</string><string>run</string><string>--dry-run</string><string>--config</string><string>%s</string></array>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/><key>ThrottleInterval</key><integer>30</integer><key>Umask</key><integer>63</integer>
</dict></plist>
`, xmlText(binary), xmlText(configPath))
	case "linux":
		path = filepath.Join(home, ".config", "systemd", "user", "agentboard-host.service")
		quote := func(s string) string {
			return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, `%`, `%%`).Replace(s) + `"`
		}
		body = fmt.Sprintf("# agentboard-host dry-run v1\n[Unit]\nDescription=Agentboard scoped wake shadow\n[Service]\nExecStart=%s host run --dry-run --config %s\nRestart=on-failure\nRestartSec=30\nUMask=0077\nNoNewPrivileges=true\n[Install]\nWantedBy=default.target\n", quote(binary), quote(configPath))
	default:
		return p, errors.New("host preview supports linux or darwin")
	}
	if _, err := os.Lstat(path); err == nil {
		return p, errors.New("existing host supervision file retained; preview refuses replacement")
	} else if !os.IsNotExist(err) {
		return p, errors.New("cannot inspect local supervision path")
	}
	p.Files = []OwnedFile{{Path: path, Hash: digest([]byte(body))}}
	p.Contents = map[string]string{path: body}
	p.Reload = []string{"No service is loaded. Separate captain approval is required for service activation and wake-owner cutover."}
	return p, nil
}
