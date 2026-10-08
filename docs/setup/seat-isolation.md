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
scripts/launch-seat --repo "$PWD" --root "$AGENTBOARD_SEAT_ROOT" --brief "$TASK_BRIEF" -- "$HARNESS_BIN" --prompt-file '{brief}'
```

Arguments after `--` are native argv, never a shell string. Include `{brief_text}`
or `{brief}` as a whole argument so the generated brief is actually delivered.
Pass `--task TASK` when the seat serves an agentboard task so the slot is
recorded on the task and the gated return can run after exit.
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

## Attach and recover without restarting an agent

The installed CLI embeds the same Python isolation engine, so another product
repository need not contain Agentboard scripts. Install **Python 3**, Git and the
pinned Treehouse v3.1.2 binary explicitly. `AGENTBOARD_TREEHOUSE_BIN` may name that
binary; recovery never installs prerequisites or claims/reclaims a task for you.

Read/claim or renew your authorized task first. From the known source repository,
run recovery only (no implementation in the primary checkout):

```sh
agentboard seat ensure TASK --repo SOURCE --root POOL
# Apply the printed export lines and cd command to your own shell/tool environment.
agentboard seat check TASK --json
pwd -P
git rev-parse --show-toplevel
```

Both physical paths must match `AGENTBOARD_SEAT_WORKTREE`. The output also sets
`AGENTBOARD_SEAT_SOURCE`, `AGENTBOARD_SEAT_ROOT`, brief path and declared identity.
`agentboard seat env TASK --repo SOURCE --root POOL` verifies and prints an existing
seat without acquiring; `--json` on ensure/env emits the selected environment and
binding for integrations. Source defaults to the explicit seat environment or the
repository's registered primary checkout. Pool must be explicit or recoverable
from a retained task record. Conflicting explicit source/root is refused.

Ensure reads all board event pages, checks a live owned claim, and serializes
same-task local acquisition. It preserves the current lease identity and WIP in a
private pool registry before recording on the board. If task recording fails,
retry ensure for the same task: it reuses the preserved lease. An interruption
between allocation and its local receipt retains a pending marker; inspect and
coordinate recovery rather than blindly allocating another slot. No automatic task
claim, worktree reset, branch creation, cleanup or credential replacement occurs.
A record pointing at a missing path on another host, a different task, stale
lease, primary or legacy/out-of-pool checkout remains a blocker; coordinate it.

Task-aware fresh native launches and explicit attachment use this same CLI:

```sh
scripts/launch-seat --repo SOURCE --root POOL --task TASK --brief TASK_BRIEF --attach -- codex '{brief_text}'
```

The updated CLI must be on PATH. Both forms reuse that task's binding and inject
all three seat variables before the child runs. Repeat attach preserves the
private brief and `agent.env`; incompatible retained identity/seat/brief metadata
fails without overwriting credentials. Legacy files lacking new metadata may need
explicit coordinated repair. Launches without `--task` remain supported but
allocate a fresh lease each time and do not provide task-bound attachment.

The commands cannot modify their parent shell or an already-running Herdr pane.
Apply the emitted exports and cwd to subsequent calls, or launch a new native
child through the attach helper. Herdr workspace create/attach integrations must
consume the selected JSON environment and use the verified worktree cwd before
starting the native agent; no global Herdr reconfiguration is performed here.

Missing environment alone can be self-healed without a coordinator round-trip.
STOP implementation until the checks pass. Genuine ownership, expiry, lease or
isolation failures still require preserving work, reporting the blocker and
coordinating recovery. Do not resume a held captain decision merely because the
environment is fixed. Never fall back to primary edits or adopt a legacy worktree.

The persistent Treehouse lease stays held after native process exit, including
launch failures after acquisition. Inspect the reported path, preserve all work,
and coordinate recovery. Keep it through PR review and green CI. Return it only
through the landed gate: with `--task TASK` the launcher records the slot
(`agentboard-seat` update) and attempts the gated return after exit when the task
is done/cancelled and landed, and `agentboard seat return TASK` runs the same
gate manually (clean tree, HEAD reachable from a remote ref; same-version
`treehouse return`, never `--force`, never `rm -rf`). A merged task also carries
the return instruction in its completion message. Without a gated return, return
only your own worktree explicitly with the pinned tool after cleanup is authorized
(v3 finds the pool from the path; legacy v2 leases use the v2 binary). Never prune another seat.
A full pool is a blocker, not permission to clear someone else's checkout.

Optional SessionStart or turn-end backstops can invoke the source launcher with
`--repo "$AGENTBOARD_SEAT_SOURCE" --check` from the real seat cwd. Installation is
explicit and harness-specific; no hooks are installed automatically. They do not
replace the launcher gate or the STOP brief. This script is a launch boundary, not
an OS sandbox against a harness that deliberately changes directory later.

The version/API/config behavior is pinned to the upstream
[v3.1.2 get implementation](https://github.com/kunchenguid/treehouse/blob/v3.1.2/cmd/get.go)
and [configuration](https://github.com/kunchenguid/treehouse/blob/v3.1.2/internal/config/config.go).
