package worker

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

//go:embed pi-native.mjs
var piExtension []byte

//go:embed codex-native.mjs
var codexBridge []byte

//go:embed claude-native/bridge.mjs claude-native/.mcp.json claude-native/.claude-plugin/plugin.json claude-native/hooks/register.js claude-native/hooks/hooks.json
var claudePlugin embed.FS

type OwnedFile struct {
	Path string `json:"path"`
	Hash string `json:"sha256"`
}
type Manifest struct {
	Owner   string      `json:"owner"`
	Version int         `json:"version"`
	Files   []OwnedFile `json:"files"`
}
type InstallPlan struct {
	Apply     bool        `json:"applied"`
	Files     []OwnedFile `json:"files"`
	Reload    []string    `json:"reload_requirements"`
	Preserved string      `json:"preserved"`
}

func digest(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func xmlText(value string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(value))
	return b.String()
}

func serviceFiles(home, configPath, platform string) (map[string][]byte, []string, error) {
	if !filepath.IsAbs(home) || !filepath.IsAbs(configPath) || strings.ContainsAny(home+configPath, "\r\n\x00") {
		return nil, nil, errors.New("installer requires absolute single-line paths")
	}
	base := filepath.Join(home, ".config", "agentboard", "worker")
	files := map[string][]byte{filepath.Join(base, "pi-native.mjs"): piExtension, filepath.Join(base, "codex-native.mjs"): codexBridge}
	if err := fs.WalkDir(claudePlugin, "claude-native", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil || entry.IsDir() {
			return walkErr
		}
		data, err := claudePlugin.ReadFile(name)
		if err == nil {
			files[filepath.Join(base, filepath.FromSlash(name))] = data
		}
		return err
	}); err != nil {
		return nil, nil, err
	}
	binary := filepath.Join(home, ".local", "bin", "agentboard")
	var reload []string
	switch platform {
	case "darwin":
		path := filepath.Join(home, "Library", "LaunchAgents", "dev.carverauto.agentboard.worker.plist")
		files[path] = []byte(fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.carverauto.agentboard.worker</string>
<key>ProgramArguments</key><array><string>%s</string><string>worker</string><string>serve</string><string>--config</string><string>%s</string></array>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/><key>ThrottleInterval</key><integer>30</integer><key>Umask</key><integer>63</integer>
</dict></plist>
`, xmlText(binary), xmlText(configPath)))
		reload = []string{"After review: launchctl bootstrap gui/UID " + path, "For replacement: launchctl bootout gui/UID/dev.carverauto.agentboard.worker then bootstrap the owned plist", "Pi: explicitly load pi-native.mjs with -e; session replacement requires verified worker bind"}
	case "linux":
		path := filepath.Join(home, ".config", "systemd", "user", "agentboard-worker.service")
		quote := func(s string) string {
			return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, `%`, `%%`).Replace(s) + `"`
		}
		files[path] = []byte(fmt.Sprintf("# agentboard-worker owned v1\n[Unit]\nDescription=Agentboard scoped worker\n[Service]\nExecStart=%s worker serve --config %s\nRestart=on-failure\nRestartSec=30\nUMask=0077\nNoNewPrivileges=true\n[Install]\nWantedBy=default.target\n", quote(binary), quote(configPath)))
		reload = []string{"After review: systemctl --user daemon-reload; systemctl --user enable --now agentboard-worker.service", "After replacement: systemctl --user restart agentboard-worker.service", "Pi: explicitly load pi-native.mjs with -e; session replacement requires verified worker bind"}
	default:
		return nil, nil, errors.New("only launchd macOS and systemd Linux are supported")
	}
	reload = append(reload, "Claude: explicitly load claude-native with --plugin-dir; native mods must be available; boundary-only delivery and verified worker bind required")
	reload = append(reload, "Codex: explicitly activate codex-native.mjs with a protected profile; dedicated ephemeral stdio child only; verify descriptor and worker bind before delivery")
	return files, reload, nil
}

// Install previews by default. It never loads services or edits harness settings.
func Install(home, configPath, platform string, apply bool) (InstallPlan, error) {
	plan := InstallPlan{Apply: apply, Preserved: "Foreign hooks/settings, protected credentials, crash journals and server obligations"}
	files, reload, err := serviceFiles(home, configPath, platform)
	if err != nil {
		return plan, err
	}
	plan.Reload = reload
	manifestPath := filepath.Join(home, ".config", "agentboard", "worker", "install.json")
	m, err := readManifest(manifestPath)
	if err != nil {
		return plan, err
	}
	old := map[string]string{}
	for _, f := range m.Files {
		old[f.Path] = f.Hash
	}
	paths := make([]string, 0, len(files))
	for path := range files {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		data := files[path]
		plan.Files = append(plan.Files, OwnedFile{path, digest(data)})
		existing, err := os.ReadFile(path)
		if err == nil {
			info, e := os.Lstat(path)
			if e != nil || !info.Mode().IsRegular() || !owned(info) || old[path] == "" || digest(existing) != old[path] {
				return plan, errors.New("refusing foreign or modified integration file")
			}
		} else if !os.IsNotExist(err) {
			return plan, errors.New("cannot inspect installation file")
		}
	}
	if !apply {
		return plan, nil
	}
	if err := PrivateDir(filepath.Dir(manifestPath)); err != nil {
		return plan, err
	}
	for path, data := range files {
		if existing, err := os.ReadFile(path); err == nil {
			if digest(existing) == digest(data) {
				continue
			}
			backup := filepath.Join(filepath.Dir(manifestPath), "backups", digest(existing)+".bak")
			if err := writeBytes(backup, existing); err != nil {
				return plan, err
			}
		}
		if err := writeOwnedFile(path, data); err != nil {
			return plan, err
		}
	}
	return plan, WriteProtected(manifestPath, Manifest{Owner: "agentboard-worker", Version: Protocol, Files: plan.Files})
}

func readManifest(path string) (Manifest, error) {
	var m Manifest
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return m, nil
	}
	data, err := ReadProtected(path, 1<<20)
	if err != nil {
		return m, err
	}
	if json.Unmarshal(data, &m) != nil || m.Owner != "agentboard-worker" || m.Version != Protocol {
		return m, errors.New("foreign or unsupported installation manifest")
	}
	return m, nil
}

func writeOwnedFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || !owned(info) || info.Mode().Perm()&0022 != 0 {
		return errors.New("unsafe service directory")
	}
	return atomicBytes(path, data)
}

// Uninstall removes only hash-matching owned files; it retains all delivery state.
func Uninstall(home, configPath, platform string, apply bool) (InstallPlan, error) {
	plan := InstallPlan{Apply: apply, Preserved: "Protected config/credentials, journals, foreign hooks and pending server obligations"}
	allowed, reload, err := serviceFiles(home, configPath, platform)
	if err != nil {
		return plan, err
	}
	plan.Reload = reload
	path := filepath.Join(home, ".config", "agentboard", "worker", "install.json")
	m, err := readManifest(path)
	if err != nil {
		return plan, err
	}
	for _, f := range m.Files {
		if _, ok := allowed[f.Path]; !ok {
			return plan, errors.New("installation manifest names an unrelated file")
		}
		if _, err := os.Lstat(f.Path); os.IsNotExist(err) {
			continue
		}
		data, err := ReadProtected(f.Path, 1<<20)
		if err != nil || digest(data) != f.Hash {
			return plan, errors.New("refusing to remove changed integration file")
		}
		plan.Files = append(plan.Files, f)
	}
	if !apply {
		return plan, nil
	}
	for _, f := range plan.Files {
		if err := os.Remove(f.Path); err != nil {
			return plan, err
		}
	}
	if m.Owner != "" {
		if err := os.Remove(path); err != nil {
			return plan, err
		}
	}
	plan.Reload = []string{"Stop/unload the previously installed service explicitly; deletion alone does not stop it", "Remove explicit Pi -e argument and restart only that enrolled session; server deliveries stay pending", "Stop only the owned Codex bridge child explicitly; retain native journals and pending server deliveries"}
	return plan, nil
}
