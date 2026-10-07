# Launch an isolated Agentboard seat

Every implementation seat uses a persistently leased disposable Treehouse linked
worktree. The launch-time assertion and the generated STOP brief both apply;
Herdr hosting does not satisfy this contract. No hooks, daemon, fleet delivery,
agent enrollment or merge is enabled by these scripts.

## Install the pinned tool

With Python 3 and curl installed, run `scripts/install-treehouse` explicitly. It downloads the official **v2.0.1**
release for Linux/Darwin AMD64/ARM64, verifies the pinned archive SHA256 and exact
binary version, and atomically installs it under
`~/.local/share/agentboard/tools/treehouse/v2.0.1/treehouse`. It leaves the global
Treehouse executable and its pools alone. An optional argument chooses a different
installation directory; set `AGENTBOARD_TREEHOUSE_BIN` to that binary. The launcher
refuses any version other than `v2.0.1`.

The repository's `treehouse.toml` selects a versioned pool rooted under
`~/.local/share/agentboard/treehouse-v2.0.1`. Treehouse appends `.treehouse` and its
repository pool name. This separates v2 state from existing newer global pools.
Changing this config is an explicit operator choice; do not point it at a pool
managed by another Treehouse version. User-level Treehouse hooks may still run;
the launcher always checks the resulting checkout after acquisition.

## Launch a native harness

Configure your stable repo-grounded `AGENT_ID`, actual `AGENTBOARD_HARNESS` and
`AGENTBOARD_MODEL` first, following the Agentboard skill. Register, inspect and
claim your assigned task through Agentboard. Put the authorized task brief in a
file, then invoke from the source repository root:

```sh
scripts/launch-seat --repo "$PWD" --brief "$TASK_BRIEF" -- codex '{brief_text}'
# For a native CLI that accepts a prompt file:
scripts/launch-seat --repo "$PWD" --brief "$TASK_BRIEF" -- "$HARNESS_BIN" --prompt-file '{brief}'
```

Arguments after `--` are native argv, never a shell string. Include `{brief_text}`
or `{brief}` as a whole argument so the generated brief is actually delivered.
Check your harness's native prompt/file option before choosing argv. The launcher
calls only the real v2 interface, `treehouse get --lease --lease-holder "$AGENT_ID"`;
it does not invent the v3 `--root`, `--base`, `--branch` or `--json` flags.
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
`AGENTBOARD_SEAT_BRIEF`. A successful launch does not prove the model followed the
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
authorized; v2 has no lease-ID-fenced return operation. Never prune another seat.
A full pool is a blocker, not permission to clear someone else's checkout.

Optional SessionStart or turn-end backstops can invoke the source launcher with
`--repo "$AGENTBOARD_SEAT_SOURCE" --check` from the real seat cwd. Installation is
explicit and harness-specific; no hooks are installed automatically. They do not
replace the launcher gate or the STOP brief. This script is a launch boundary, not
an OS sandbox against a harness that deliberately changes directory later.

The version/API/config behavior is pinned to the upstream
[v2.0.1 get implementation](https://github.com/kunchenguid/treehouse/blob/v2.0.1/cmd/get.go)
and [configuration](https://github.com/kunchenguid/treehouse/blob/v2.0.1/internal/config/config.go).
