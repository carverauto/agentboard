package seatops

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
)

// SpawnRequest asks a host to open a new tab for one seat and start argv in
// its fresh pane. A host never delivers argv to a pane it did not just create.
type SpawnRequest struct {
	// Label names the new tab: the seat's agent ID.
	Label string
	// Workspace is the host container label the tab belongs in.
	Workspace string
	// Cwd is the absolute directory the new tab starts in.
	Cwd string
	// Env is the non-secret environment of the new tab's shell.
	Env map[string]string
	// Argv is the command the new pane runs.
	Argv []string
}

// SpawnedSeat is the host identity of a spawned seat.
type SpawnedSeat struct {
	Workspace        string `json:"workspace_id"`
	Tab              string `json:"tab_id"`
	Pane             string `json:"pane_id"`
	CreatedWorkspace bool   `json:"created_workspace"`
}

// ErrSeatExists means the host already has a pane or tab with the seat's name.
var ErrSeatExists = errors.New("seat already exists on this host")

// notStarted marks a spawn error raised before the host created any tab or
// pane, so retrying the same launch cannot open a second one.
type notStarted struct{ error }

func (e notStarted) Unwrap() error { return e.error }

// NotStarted reports whether err refused a spawn before the host created a
// tab or pane.
func NotStarted(err error) bool {
	var refused notStarted
	return errors.As(err, &refused)
}

// DefaultSpawnConfigPath is ~/.config/agentboard/fleet/harnesses.json.
func DefaultSpawnConfigPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "agentboard", "fleet", "harnesses.json")
}

// SpawnConfig is the host-local harness allowlist. Only argv listed here can
// ever start in a spawned seat; nothing in it comes from the board.
type SpawnConfig struct {
	Version int `json:"version"`
	// Launcher is the absolute path of scripts/launch-seat, the pane command
	// that leases the Treehouse worktree and starts the harness in it.
	Launcher string `json:"launcher"`
	// Repo and Root default the source checkout and Treehouse v3 pool root.
	Repo string `json:"repo,omitempty"`
	Root string `json:"root,omitempty"`
	// Workspace labels the host container seat tabs open in.
	Workspace string `json:"workspace,omitempty"`
	// BriefDir holds generated briefs for spawns without --brief.
	BriefDir  string             `json:"brief_dir,omitempty"`
	Harnesses map[string]Harness `json:"harnesses"`
}

// Harness is one allowlisted native harness: the model it runs and its argv
// template, which consumes {brief} or {brief_text} as a whole argument.
type Harness struct {
	Model string   `json:"model"`
	Argv  []string `json:"argv"`
}

var (
	harnessName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)
	seatSlug    = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,127}$`)
)

// LoadSpawnConfig reads the allowlist at path. It refuses a relative path, a
// missing file, a symlink, a file another user owns or anyone else can write,
// and any entry launch-seat would refuse.
func LoadSpawnConfig(path string) (SpawnConfig, error) {
	var cfg SpawnConfig
	if !filepath.IsAbs(path) {
		return cfg, fmt.Errorf("refuses: harness allowlist path %q must be absolute", path)
	}
	raw, err := readPrivateFile(path, "harness allowlist")
	if err != nil {
		return cfg, err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("%s: %w", path, err)
	}
	if cfg.Version != 1 {
		return cfg, fmt.Errorf("%s: unsupported version %d", path, cfg.Version)
	}
	home, _ := os.UserHomeDir()
	if cfg.Workspace == "" {
		cfg.Workspace = "agentboard-seats"
	}
	if cfg.BriefDir == "" {
		cfg.BriefDir = filepath.Join(home, ".local", "state", "agentboard", "fleet", "briefs")
	}
	cfg.Launcher, cfg.Repo, cfg.Root, cfg.BriefDir = expandHome(cfg.Launcher, home), expandHome(cfg.Repo, home), expandHome(cfg.Root, home), expandHome(cfg.BriefDir, home)
	for name, value := range map[string]string{"launcher": cfg.Launcher, "brief_dir": cfg.BriefDir, "repo": cfg.Repo, "root": cfg.Root} {
		if (value != "" || name == "launcher") && !filepath.IsAbs(value) {
			return cfg, fmt.Errorf("%s: %s %q must be absolute", path, name, value)
		}
	}
	if err := checkLauncher(cfg.Launcher); err != nil {
		return cfg, fmt.Errorf("%s: %w", path, err)
	}
	if len(cfg.Harnesses) == 0 {
		return cfg, fmt.Errorf("%s: no harnesses are allowlisted", path)
	}
	for name, h := range cfg.Harnesses {
		if !harnessName.MatchString(name) {
			return cfg, fmt.Errorf("%s: harness name %q must be a lowercase slug", path, name)
		}
		if strings.TrimSpace(h.Model) == "" {
			return cfg, fmt.Errorf("%s: harness %s needs a model", path, name)
		}
		if len(h.Argv) == 0 || h.Argv[0] == "" || strings.Contains(h.Argv[0], "{") {
			return cfg, fmt.Errorf("%s: harness %s argv must start with its program", path, name)
		}
		if !consumesBrief(h.Argv) {
			return cfg, fmt.Errorf("%s: harness %s argv must consume {brief} or {brief_text} as a whole argument", path, name)
		}
	}
	return cfg, nil
}

func consumesBrief(argv []string) bool {
	for _, arg := range argv {
		if arg == "{brief}" || arg == "{brief_text}" {
			return true
		}
	}
	return false
}

// readPrivateFile reads a regular file without following a final symlink and
// refuses one another user owns or anyone else can write.
func readPrivateFile(path, what string) ([]byte, error) {
	info, err := os.Lstat(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return nil, fmt.Errorf("refuses: no %s at %s", what, path)
	case err != nil:
		return nil, err
	case info.Mode()&os.ModeSymlink != 0:
		return nil, fmt.Errorf("refuses: %s %s must not be a symlink", what, path)
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("refuses: %s %s: %w", what, path, err)
	}
	defer file.Close()
	if err := privateRegular(file, path, what); err != nil {
		return nil, err
	}
	raw, err := io.ReadAll(io.LimitReader(file, 1<<20+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > 1<<20 {
		return nil, fmt.Errorf("refuses: %s %s exceeds 1 MiB", what, path)
	}
	return raw, nil
}

func privateRegular(file *os.File, path, what string) error {
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("refuses: %s %s must be a regular file", what, path)
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("refuses: %s %s must not be group/world writable", what, path)
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Getuid() {
		return fmt.Errorf("refuses: %s %s must be owned by the current user", what, path)
	}
	return nil
}

func checkLauncher(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("launcher %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("launcher %s must be a regular file, not a symlink", path)
	}
	if info.Mode().Perm()&0o111 == 0 || info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("launcher %s must be executable and not group/world writable", path)
	}
	return nil
}

// SpawnOptions are one spawn's caller inputs. Repo and Root override the
// allowlist defaults; an empty Brief generates one, which needs Task.
type SpawnOptions struct {
	Task, Agent, Harness string
	Brief                string
	Repo, Root           string
	BoardURL             string
}

// SpawnPlan is everything a spawn would do, decided before any host call.
type SpawnPlan struct {
	Task      string            `json:"task,omitempty"`
	Agent     string            `json:"agent"`
	Harness   string            `json:"harness"`
	Model     string            `json:"model"`
	Workspace string            `json:"workspace"`
	Cwd       string            `json:"cwd"`
	Brief     string            `json:"brief"`
	BriefText string            `json:"brief_text,omitempty"`
	Env       map[string]string `json:"env"`
	Argv      []string          `json:"argv"`
}

// PlanSpawn resolves a spawn from the host-local allowlist. It is pure apart
// from checking that the named paths exist. The pane command is launch-seat,
// which leases the Treehouse worktree, writes the STOP brief and runs the
// harness there; the tab itself opens in the source checkout.
func PlanSpawn(cfg SpawnConfig, opts SpawnOptions) (SpawnPlan, error) {
	if !seatSlug.MatchString(opts.Agent) || (opts.Task != "" || opts.Brief == "") && !seatSlug.MatchString(opts.Task) {
		return SpawnPlan{}, errors.New("refuses: agent and task IDs must be lowercase slugs")
	}
	h, ok := cfg.Harnesses[opts.Harness]
	if !ok {
		return SpawnPlan{}, fmt.Errorf("refuses: harness %q is not in the host allowlist", opts.Harness)
	}
	repo, root := firstNonEmpty(opts.Repo, cfg.Repo), firstNonEmpty(opts.Root, cfg.Root)
	for name, dir := range map[string]string{"source repository": repo, "Treehouse pool root": root} {
		if !filepath.IsAbs(dir) {
			return SpawnPlan{}, fmt.Errorf("refuses: %s %q must be absolute", name, dir)
		}
		if info, err := os.Stat(dir); err != nil || !info.IsDir() {
			return SpawnPlan{}, fmt.Errorf("refuses: %s %s is not a directory", name, dir)
		}
	}
	if opts.BoardURL == "" {
		return SpawnPlan{}, errors.New("refuses: AGENTBOARD_URL is required so the seat reaches the board")
	}
	plan := SpawnPlan{Task: opts.Task, Agent: opts.Agent, Harness: opts.Harness, Model: h.Model, Workspace: cfg.Workspace, Cwd: repo, Brief: opts.Brief}
	if plan.Brief == "" {
		plan.Brief = filepath.Join(cfg.BriefDir, opts.Agent+"--"+opts.Task+".md")
		plan.BriefText = spawnBrief(opts.Agent, opts.Harness, h.Model, opts.Task)
	} else {
		abs, err := filepath.Abs(plan.Brief)
		if err != nil {
			return SpawnPlan{}, err
		}
		if info, err := os.Stat(abs); err != nil || !info.Mode().IsRegular() {
			return SpawnPlan{}, fmt.Errorf("refuses: brief %s is not a readable file", abs)
		}
		plan.Brief = abs
	}
	plan.Env = map[string]string{"AGENT_ID": opts.Agent, "AGENTBOARD_HARNESS": opts.Harness, "AGENTBOARD_MODEL": h.Model, "AGENTBOARD_URL": opts.BoardURL, "AGENTBOARD_SEAT_SOURCE": repo, "AGENTBOARD_SEAT_ROOT": root}
	plan.Argv = append([]string{cfg.Launcher, "--repo", repo, "--root", root, "--brief", plan.Brief, "--"}, h.Argv...)
	return plan, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func spawnBrief(agent, harness, model, task string) string {
	return fmt.Sprintf(`# Agentboard seat %s

You were started by agentboard seat spawn as %s (harness %s, model %s) for
board task %s. The board is the only authority for what you work on.

1. Register from this pane: agentboard agent register --backend herdr --json
2. Run your agentboard check-in. Claim %s only if the board assigns or orders it
   to you; otherwise follow what the board shows.
`, agent, agent, harness, model, task, task)
}

// SpawnReport is the outcome of one spawn.
type SpawnReport struct {
	DryRun bool `json:"dry_run"`
	SpawnPlan
	Spawned *SpawnedSeat `json:"spawned,omitempty"`
}

// Spawn refuses when the host is unavailable or already has a seat named
// plan.Agent, then, with apply, writes a generated brief and asks the host to
// open the seat's new tab. Without apply it changes nothing.
func Spawn(ctx context.Context, host Host, plan SpawnPlan, apply bool) (SpawnReport, error) {
	report := SpawnReport{DryRun: !apply, SpawnPlan: plan}
	panes, err := host.Agents(ctx)
	if err != nil {
		return report, notStarted{fmt.Errorf("refuses: seat host unavailable: %w", err)}
	}
	for _, p := range panes {
		if p.Name == plan.Agent {
			return report, notStarted{fmt.Errorf("refuses: pane %s is already named %s: %w", p.Pane, plan.Agent, ErrSeatExists)}
		}
	}
	if !apply {
		return report, nil
	}
	if plan.BriefText != "" {
		if err := writePrivate(plan.Brief, plan.BriefText); err != nil {
			return report, notStarted{fmt.Errorf("write brief: %w", err)}
		}
	}
	seat, err := host.Spawn(ctx, SpawnRequest{Label: plan.Agent, Workspace: plan.Workspace, Cwd: plan.Cwd, Env: plan.Env, Argv: plan.Argv})
	if seat.Pane != "" {
		report.Spawned = &seat
	}
	return report, err
}

// writePrivate replaces path atomically with a 0600 file in a 0700 directory.
func writePrivate(path, text string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".brief-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// shellCommand renders argv as one POSIX shell command line.
func shellCommand(argv []string) string {
	quoted := make([]string, len(argv))
	for i, arg := range argv {
		quoted[i] = shellQuote(arg)
	}
	return strings.Join(quoted, " ")
}

var shellSafe = regexp.MustCompile(`^[A-Za-z0-9_@%+=:,./-]+$`)

func shellQuote(arg string) string {
	if shellSafe.MatchString(arg) {
		return arg
	}
	return "'" + strings.ReplaceAll(arg, "'", `'\''`) + "'"
}

func sortedEnv(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
