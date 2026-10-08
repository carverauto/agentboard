# Launch an isolated Agentboard seat

Every implementation seat uses a persistently leased disposable Treehouse linked
worktree. The launch-time assertion and the generated STOP brief both apply;
Herdr hosting does not satisfy this contract. No hooks, daemon, fleet delivery,
agent enrollment or merge is enabled by these scripts.

## Install the pinned tool

With Python 3 and curl installed, run `scripts/install-treehouse` explicitly. It downloads the official **v3.1.2**
release for Linux/Darwin AMD64/ARM64, verifies the pinned archive SHA256 and exact
binary version, and atomically installs it under
`~/.local/share/agentboard/tools/treehouse/v3.1.2/treehouse`. It leaves the global
Treehouse executable and its pools alone. An optional argument chooses a different
installation directory; set `AGENTBOARD_TREEHOUSE_BIN` to that binary. The launcher
refuses any version other than `v3.1.2`.

## Choose an explicit v3 pool root

The launcher never relies on `treehouse.toml` or `TREEHOUSE_ROOT` for the pool.
Pass an absolute root with `--root PATH`, or set `AGENTBOARD_SEAT_ROOT`; the flag
wins. The launcher passes it to `treehouse get --root`, which overrides
`TREEHOUSE_ROOT` and config. Treehouse appends `.treehouse` and the repository
pool name, so one root holds a separate pool per repository. Before acquiring, the
launcher reads every `<root>/.treehouse/*/treehouse-state.json` and refuses the
root (STOP, nothing created) if any pool lacks the integer state `version` that v3
writes, i.e. a pool managed by Treehouse v2. It also refuses relative or symlinked
roots and any leased path outside `<root>/.treehouse`. Sharing a root with other
v3.1.2 seats that use the same explicit root is fine; never point it at a v2 pool.

Migration from v2: existing seats that already hold leases in the legacy v2 pool
(`~/.local/share/agentboard/treehouse-v2.0.1`, still named by this repository's
`treehouse.toml`) keep working. `--check` uses only Git and the seat environment,
so it is unaffected. Do not move, prune or reuse those leases with v3. Keep the old
v2 binary at `~/.local/share/agentboard/tools/treehouse/v2.0.1/treehouse` until
every v2 lease is returned with that binary's `return PATH`. Launch new seats with
an absolute per-repository v3 root (for example `/path/to/agentboard-seats-v3`).
The maintainers' workstation roots are recorded in
[reference-farm01.md](../deploy/reference-farm01.md#seat-pool-roots).
User-level Treehouse hooks may still run; the launcher always checks the resulting
checkout after acquisition.

## Launch a native harness

Configure your stable repo-grounded `AGENT_ID`, actual `AGENTBOARD_HARNESS` and
`AGENTBOARD_MODEL` first, following the Agentboard skill. Register, inspect and
claim your assigned task through Agentboard. Put the authorized task brief in a
file, then invoke from the source repository root:

```sh
scripts/launch-seat --repo "$PWD" --root "$AGENTBOARD_SEAT_ROOT" --brief "$TASK_BRIEF" -- codex '{brief_text}'
# For a native CLI that accepts a prompt file:
scripts/launch-seat --repo "$PWD" --brief "$TASK_BRIEF" -- "$HARNESS_BIN" --prompt-file '{brief}'
```

Arguments after `--` are native argv, never a shell string. Include `{brief_text}`
or `{brief}` as a whole argument so the generated brief is actually delivered.
Check your harness's native prompt/file option before choosing argv. The launcher
calls only the real v3 interface,
`treehouse get --lease --lease-holder "$AGENT_ID" --root "$ROOT"`; it does not pass
`--base`, `--branch` or `--json`.
Treehouse chooses the default branch tip for acquisition. Inspect the acquired
base against freshly fetched `origin/main` before starting a new feature branch;
do not reuse a stale task or overwrite another seat's work.

The launcher refuses inherited `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR` or
`GIT_INDEX_FILE` before anything else; unset them and retry. It then requires
two consecutive checks of the physical cwd and Git root, rejects the
primary/spawning checkout, subdirectories, unrelated repositories and
unregistered worktrees, then writes a private brief inside `.agentboard-seat/`
(directory mode 0700, brief file mode 0600, symlinks and redirected paths rejected).
It checks again immediately before starting the harness with that exact cwd.
The child inherits `AGENTBOARD_SEAT_WORKTREE`, `AGENTBOARD_SEAT_SOURCE` and
`AGENTBOARD_SEAT_BRIEF` and `AGENTBOARD_SEAT_ROOT`. A successful launch does not prove the model followed the
brief; the harness must perform its own startup check before editing.

## STOP and recovery

At startup and in every ship brief, require `pwd -P` and
`git rev-parse --show-toplevel` to match the expected physical
`AGENTBOARD_SEAT_WORKTREE`. Run the source checkout's launcher `--check` from the
seat cwd. Missing metadata or any mismatch means STOP: no branching, editing,
commit or push. Report the failure to your coordinator; reread the task and mark
it blocked only if your claim is still live. For a primary launch, report
`launched in primary checkout, not an isolated worktree` on the task and status
channel if one exists. Resume only in a correctly leased
worktree. Do not silently fall back to the primary checkout.

The persistent Treehouse lease stays held after native process exit, including
launch failures after acquisition. Inspect the reported path, preserve all work,
and coordinate recovery. Keep it through PR review and green CI. Return only your
own worktree explicitly using the pinned tool's `return PATH` after cleanup is
authorized (v3 finds the pool from the path; legacy v2 leases use the v2 binary). Never prune another seat.
A full pool is a blocker, not permission to clear someone else's checkout.

Optional SessionStart or turn-end backstops can invoke the source launcher with
`--repo "$AGENTBOARD_SEAT_SOURCE" --check` from the real seat cwd. Installation is
explicit and harness-specific; no hooks are installed automatically. They do not
replace the launcher gate or the STOP brief. This script is a launch boundary, not
an OS sandbox against a harness that deliberately changes directory later.

The version/API/config behavior is pinned to the upstream
[v3.1.2 get implementation](https://github.com/kunchenguid/treehouse/blob/v3.1.2/cmd/get.go)
and [configuration](https://github.com/kunchenguid/treehouse/blob/v3.1.2/internal/config/config.go).
