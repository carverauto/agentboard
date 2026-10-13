package seatops

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func (h *fakeHost) Spawn(context.Context, SpawnRequest) (SpawnedSeat, error) {
	return SpawnedSeat{}, errors.New("fakeHost does not spawn")
}

// recordingHerdr writes a herdr stand-in that answers "$1 $2" from replies
// (unknown subcommands fail) and records every call's exact argv.
func recordingHerdr(t *testing.T, replies map[string]string) (HerdrCLI, func() [][]string) {
	t.Helper()
	dir := t.TempDir()
	bin, log := filepath.Join(dir, "herdr"), filepath.Join(dir, "calls.log")
	script := "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\037' \"$a\" >> '" + log + "'; done\nprintf '\\n' >> '" + log + "'\ncase \"$1 $2\" in\n"
	for key, reply := range replies {
		script += "\"" + key + "\") cat <<'JSON'\n" + reply + "\nJSON\n;;\n"
	}
	script += "*) echo \"unexpected herdr $*\" >&2; exit 2 ;;\nesac\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	calls := func() [][]string {
		raw, err := os.ReadFile(log)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			t.Fatal(err)
		}
		var out [][]string
		for _, line := range strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n") {
			out = append(out, strings.Split(strings.TrimSuffix(line, "\x1f"), "\x1f"))
		}
		return out
	}
	return HerdrCLI{Bin: bin}, calls
}

func spawnRequest() SpawnRequest {
	return SpawnRequest{Label: "codex-b", Workspace: "agentboard-seats", Cwd: "/src/repo",
		Env:  map[string]string{"AGENT_ID": "codex-b", "AGENTBOARD_MODEL": "gpt 5"},
		Argv: []string{"/opt/launch-seat", "--brief", "/briefs/codex b.md", "--", "codex", "{brief}", "it's"}}
}

func TestHerdrSpawnCreatesWorkspaceAndRunsOnlyInTheNewPane(t *testing.T) {
	herdr, calls := recordingHerdr(t, map[string]string{
		"workspace list":   `{"result":{"workspaces":[{"workspace_id":"w1","label":"other"}]}}`,
		"workspace create": `{"result":{"workspace":{"workspace_id":"w2"},"tab":{"tab_id":"w2:t1"}}}`,
		"tab create":       `{"result":{"tab":{"tab_id":"w2:t2"},"root_pane":{"pane_id":"w2:p2"}}}`,
		"pane run":         `{"result":{}}`,
	})
	seat, err := herdr.Spawn(context.Background(), spawnRequest())
	if err != nil {
		t.Fatal(err)
	}
	if seat != (SpawnedSeat{Workspace: "w2", Tab: "w2:t2", Pane: "w2:p2", CreatedWorkspace: true}) {
		t.Fatalf("seat = %+v", seat)
	}
	want := [][]string{
		{"workspace", "list"},
		{"workspace", "create", "--cwd", "/src/repo", "--label", "agentboard-seats", "--no-focus"},
		{"tab", "create", "--workspace", "w2", "--cwd", "/src/repo", "--label", "codex-b", "--no-focus", "--env", "AGENTBOARD_MODEL=gpt 5", "--env", "AGENT_ID=codex-b"},
		{"pane", "run", "w2:p2", `/opt/launch-seat --brief '/briefs/codex b.md' -- codex '{brief}' 'it'\''s'`},
	}
	if got := calls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("herdr calls:\n got %q\nwant %q", got, want)
	}
}

func TestHerdrSpawnReusesTheLabelledWorkspace(t *testing.T) {
	herdr, calls := recordingHerdr(t, map[string]string{
		"workspace list": `{"result":{"workspaces":[{"workspace_id":"w3","label":"agentboard-seats"}]}}`,
		"tab list":       `{"result":{"tabs":[{"tab_id":"w3:t1","label":"claude-a"}]}}`,
		"tab create":     `{"result":{"tab":{"tab_id":"w3:t4"},"root_pane":{"pane_id":"w3:p9"}}}`,
		"pane run":       `{"result":{}}`,
	})
	seat, err := herdr.Spawn(context.Background(), spawnRequest())
	if err != nil {
		t.Fatal(err)
	}
	if seat != (SpawnedSeat{Workspace: "w3", Tab: "w3:t4", Pane: "w3:p9"}) {
		t.Fatalf("seat = %+v", seat)
	}
	got := calls()
	if len(got) != 4 || got[1][0] != "tab" || got[1][1] != "list" || got[3][2] != "w3:p9" {
		t.Fatalf("herdr calls = %q", got)
	}
}

func TestHerdrSpawnRefusesBeforeCreatingAnything(t *testing.T) {
	for name, workspaces := range map[string]string{
		"taken tab label":     `{"result":{"workspaces":[{"workspace_id":"w3","label":"agentboard-seats"}]}}`,
		"ambiguous workspace": `{"result":{"workspaces":[{"workspace_id":"w3","label":"agentboard-seats"},{"workspace_id":"w4","label":"agentboard-seats"}]}}`,
	} {
		t.Run(name, func(t *testing.T) {
			herdr, calls := recordingHerdr(t, map[string]string{
				"workspace list": workspaces,
				"tab list":       `{"result":{"tabs":[{"tab_id":"w3:t1","label":"codex-b"}]}}`,
			})
			if _, err := herdr.Spawn(context.Background(), spawnRequest()); err == nil || !strings.Contains(err.Error(), "refuses") {
				t.Fatalf("err = %v", err)
			}
			for _, call := range calls() {
				if call[1] == "create" || call[1] == "run" {
					t.Fatalf("refused spawn still ran %q", call)
				}
			}
		})
	}
}

func spawnFixture(t *testing.T) (SpawnConfig, string) {
	t.Helper()
	dir := t.TempDir()
	launcher := filepath.Join(dir, "launch-seat")
	if err := os.WriteFile(launcher, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, sub := range []string{"repo", "pool"} {
		if err := os.Mkdir(filepath.Join(dir, sub), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	return SpawnConfig{Version: 1, Launcher: launcher, Repo: filepath.Join(dir, "repo"), Root: filepath.Join(dir, "pool"),
		Workspace: "agentboard-seats", BriefDir: filepath.Join(dir, "briefs"),
		Harnesses: map[string]Harness{"codex": {Model: "gpt-5.5", Argv: []string{"codex", "exec", "{brief}"}}}}, dir
}

func TestPlanSpawnBuildsTheLaunchSeatCommand(t *testing.T) {
	cfg, dir := spawnFixture(t)
	plan, err := PlanSpawn(cfg, SpawnOptions{Task: "ship-it", Agent: "codex-b", Harness: "codex", BoardURL: "https://board.example"})
	if err != nil {
		t.Fatal(err)
	}
	brief := filepath.Join(dir, "briefs", "codex-b--ship-it.md")
	wantArgv := []string{cfg.Launcher, "--repo", cfg.Repo, "--root", cfg.Root, "--brief", brief, "--", "codex", "exec", "{brief}"}
	if !reflect.DeepEqual(plan.Argv, wantArgv) || plan.Cwd != cfg.Repo || plan.Brief != brief {
		t.Fatalf("plan = %+v", plan)
	}
	wantEnv := map[string]string{"AGENT_ID": "codex-b", "AGENTBOARD_HARNESS": "codex", "AGENTBOARD_MODEL": "gpt-5.5", "AGENTBOARD_URL": "https://board.example", "AGENTBOARD_SEAT_SOURCE": cfg.Repo, "AGENTBOARD_SEAT_ROOT": cfg.Root}
	if !reflect.DeepEqual(plan.Env, wantEnv) {
		t.Fatalf("env = %v", plan.Env)
	}
	if !strings.Contains(plan.BriefText, "ship-it") || !strings.Contains(plan.BriefText, "register --backend herdr") {
		t.Fatalf("generated brief = %q", plan.BriefText)
	}

	if _, err := PlanSpawn(cfg, SpawnOptions{Task: "ship-it", Agent: "codex-b", Harness: "muse", BoardURL: "https://board.example"}); err == nil || !strings.Contains(err.Error(), `harness "muse" is not in the host allowlist`) {
		t.Fatalf("unknown harness err = %v", err)
	}
}

func TestSpawnWritesTheBriefOnlyWhenApplied(t *testing.T) {
	cfg, _ := spawnFixture(t)
	plan, err := PlanSpawn(cfg, SpawnOptions{Task: "ship-it", Agent: "codex-b", Harness: "codex", BoardURL: "https://board.example"})
	if err != nil {
		t.Fatal(err)
	}
	herdr, calls := recordingHerdr(t, map[string]string{
		"agent list":       `{"result":{"agents":[{"pane_id":"w1:p1","name":"codex-a"}]}}`,
		"workspace list":   `{"result":{"workspaces":[]}}`,
		"workspace create": `{"result":{"workspace":{"workspace_id":"w2"}}}`,
		"tab create":       `{"result":{"tab":{"tab_id":"w2:t2"},"root_pane":{"pane_id":"w2:p2"}}}`,
		"pane run":         `{"result":{}}`,
	})
	report, err := Spawn(context.Background(), herdr, plan, false)
	if err != nil || !report.DryRun || report.Spawned != nil {
		t.Fatalf("dry run = %+v, %v", report, err)
	}
	if got := calls(); len(got) != 1 || got[0][1] != "list" {
		t.Fatalf("dry run herdr calls = %q", got)
	}
	if _, err := os.Stat(plan.Brief); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("dry run wrote the brief: %v", err)
	}

	report, err = Spawn(context.Background(), herdr, plan, true)
	if err != nil || report.Spawned == nil || report.Spawned.Pane != "w2:p2" {
		t.Fatalf("apply = %+v, %v", report, err)
	}
	info, err := os.Stat(plan.Brief)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("brief = %v, %v", info, err)
	}
}

func TestSpawnRefusesANamedSeatAndAnUnavailableHost(t *testing.T) {
	cfg, _ := spawnFixture(t)
	plan, err := PlanSpawn(cfg, SpawnOptions{Task: "ship-it", Agent: "codex-b", Harness: "codex", BoardURL: "https://board.example"})
	if err != nil {
		t.Fatal(err)
	}
	taken, calls := recordingHerdr(t, map[string]string{"agent list": `{"result":{"agents":[{"pane_id":"w1:p1","name":"codex-b"}]}}`})
	if _, err := Spawn(context.Background(), taken, plan, true); !errors.Is(err, ErrSeatExists) {
		t.Fatalf("collision err = %v", err)
	}
	if got := calls(); len(got) != 1 {
		t.Fatalf("collision herdr calls = %q", got)
	}
	missing := HerdrCLI{Bin: filepath.Join(t.TempDir(), "no-herdr")}
	if _, err := Spawn(context.Background(), missing, plan, true); err == nil || !strings.Contains(err.Error(), "host unavailable") {
		t.Fatalf("unavailable err = %v", err)
	}
	if _, err := os.Stat(plan.Brief); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("refused spawn wrote the brief: %v", err)
	}
}

func TestLoadSpawnConfigRefusals(t *testing.T) {
	_, dir := spawnFixture(t)
	launcher := filepath.Join(dir, "launch-seat")
	valid := `{"version":1,"launcher":"` + launcher + `","harnesses":{"codex":{"model":"gpt-5.5","argv":["codex","{brief_text}"]}}}`
	write := func(name, body string, mode os.FileMode) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
		return path
	}
	good := write("good.json", valid, 0o600)
	cfg, err := LoadSpawnConfig(good)
	if err != nil || cfg.Workspace != "agentboard-seats" || cfg.Launcher != launcher {
		t.Fatalf("valid config = %+v, %v", cfg, err)
	}
	link := filepath.Join(dir, "link.json")
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	launcherLink := filepath.Join(dir, "launch-link")
	if err := os.Symlink(launcher, launcherLink); err != nil {
		t.Fatal(err)
	}
	cases := map[string]struct{ path, want string }{
		"relative path":     {"harnesses.json", "must be absolute"},
		"missing file":      {filepath.Join(dir, "absent.json"), "no harness allowlist"},
		"symlinked file":    {link, "must not be a symlink"},
		"group writable":    {write("loose.json", valid, 0o620), "group/world writable"},
		"no brief arg":      {write("nobrief.json", strings.Replace(valid, `"{brief_text}"`, `"--prompt={brief}"`, 1), 0o600), "must consume {brief}"},
		"symlink launcher":  {write("linked.json", strings.Replace(valid, launcher, launcherLink, 1), 0o600), "not a symlink"},
		"relative launcher": {write("rel.json", strings.Replace(valid, launcher, "scripts/launch-seat", 1), 0o600), "must be absolute"},
		"unknown field":     {write("extra.json", strings.Replace(valid, `"version":1`, `"version":1,"server_argv":["sh"]`, 1), 0o600), "unknown field"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := LoadSpawnConfig(tc.path); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want %q", err, tc.want)
			}
		})
	}
}
