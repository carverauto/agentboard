# Spawn a seat in a new Herdr tab

`agentboard seat spawn` starts one seat on the machine that hosts the Herdr
server. It opens a new Herdr tab labelled with the seat's agent ID and runs
[`scripts/launch-seat`](seat-isolation.md) in it. The launcher leases a
Treehouse v3 worktree, writes the STOP brief and starts the harness in that
worktree. The spawn command is a helper. It decides nothing on its own and
never writes to the board.

```sh
agentboard seat spawn --task TASK --agent AGENT_ID --harness codex            # dry run: prints the plan as JSON
agentboard seat spawn --task TASK --agent AGENT_ID --harness codex --apply    # opens the tab and starts the seat
```

## What it runs

The harness command never comes from the board. It comes from a host-local
allowlist, `~/.config/agentboard/fleet/harnesses.json` by default (`--config`
takes another absolute path):

```json
{
  "version": 1,
  "launcher": "/path/to/agentboard/scripts/launch-seat",
  "repo": "/path/to/source-checkout",
  "root": "/path/to/agentboard-seats-v3",
  "workspace": "agentboard-seats",
  "brief_dir": "~/.local/state/agentboard/fleet/briefs",
  "harnesses": {
    "codex": {"model": "gpt-5.5", "argv": ["codex", "{brief_text}"]},
    "claude": {"model": "claude-opus-5-5", "argv": ["claude", "{brief_text}"]}
  }
}
```

| Field | Meaning |
| --- | --- |
| `launcher` | Absolute path of `scripts/launch-seat`. Must be a regular executable file, not a symlink, and not group or world writable |
| `repo`, `root` | Default source checkout and Treehouse v3 pool root. `--repo` and `--root` override them. Both must be absolute directories |
| `workspace` | Label of the Herdr workspace that seat tabs open in (default `agentboard-seats`) |
| `brief_dir` | Where generated briefs are written (default shown) |
| `harnesses` | Harness name → the model it runs and its native argv. The argv must use `{brief}` or `{brief_text}` as a whole argument, as `launch-seat` requires |

The harness name becomes the seat's `AGENTBOARD_HARNESS`, so use the real
harness (`codex`, `claude`, …). `seat nudge` matches the Herdr agent kind to it.
The allowlist must be a regular file owned by you, not group/world writable and
not a symlink. Unknown fields are rejected.

## What a dry run checks

A dry run and `--apply` both ask Herdr for its agent list first. A pane
already named `AGENT_ID` stops the command, and nothing is opened. A dry run
then prints the plan as JSON. It does not write a brief, create a workspace
or tab, or run the launcher. Workspace and tab-label checks happen only on
`--apply`.

## What happens on `--apply`

1. Without `--brief`, a short brief is written to
   `brief_dir/AGENT_ID--TASK.md` (mode 0600). It tells the seat to load
   `.agentboard-seat/agent.env` for every agentboard command, register with
   `--backend herdr`, and check in by reading its unread messages and owned
   tasks, then claiming each card assigned or ordered to it. It claims `TASK`
   only if the board gives it that task.
2. Spawn finds the one Herdr workspace labelled `workspace` and creates it with
   `workspace create --cwd REPO --label WORKSPACE --no-focus` if none exists.
   When several workspaces share the label, or the workspace already has a tab
   labelled `AGENT_ID`, spawn stops.
3. It creates the seat's tab with `tab create --workspace W --cwd REPO --label
   AGENT_ID --no-focus`. The tab's environment carries `AGENT_ID`,
   `AGENTBOARD_HARNESS`, `AGENTBOARD_MODEL`, `AGENTBOARD_URL`,
   `AGENTBOARD_SEAT_SOURCE` and `AGENTBOARD_SEAT_ROOT`.
4. It runs `pane run` on the root pane that `tab create` just returned, passing
   `launcher --repo REPO --root ROOT --brief BRIEF -- argv…` as one shell-quoted
   command. That is the only pane spawn ever sends input to.

The tab opens in the source checkout because that is where `launch-seat` is
invoked. The launcher acquires the worktree, checks isolation twice and starts
the harness inside the leased worktree. A refusal from the launcher stays on
screen in the new tab. Spawn does not pass `--task` to the launcher, because a
task-bound launch needs the seat's own live claim and a new seat has not
claimed yet. So the slot is a plain persistent lease held by `AGENT_ID`, and
`seat reap` returns it under the usual landed-work rules.

Spawn never forwards `AGENTBOARD_TOKEN`. If the board requires a per-agent
token, provide it the way you do for any seat on this host, for example
`AGENTBOARD_TOKEN_FILE` in the shell profile.

A successful dry run and a successful `--apply` both print the plan as JSON
(`argv`, `env`, `cwd`, `brief`, and `brief_text` when the brief is generated).
After `--apply` the report also contains `spawned` with the Herdr
`workspace_id`, `tab_id`, `pane_id` and `created_workspace`. If the tab was
created but `pane run` failed, the report still names the new pane. Check that
pane before you close it.

## Refusals

Spawn stops with a `refuses:` error, and nothing is opened, when:

- the allowlist path is relative, missing, a symlink, owned by someone else or
  writable by others
- `--task` or `--agent` is not a lowercase slug (a letter or digit, then letters,
  digits, `_` or `-`, at most 128 characters)
- the harness is not in the allowlist
- a Herdr pane is already named `AGENT_ID`, or the workspace already has a
  tab labelled `AGENT_ID`
- several Herdr workspaces carry the configured label
- Herdr is not installed or its server is not answering
- the source checkout, pool root or `--brief` file does not exist, or
  neither `AGENTBOARD_URL` nor `--url` sets the board URL

`--apply` and `--dry-run` cannot be combined. Without either flag the command
is a dry run.

## Seat supply

[`agentboard host fleet serve`](fleet-host.md) launches seats the server asks
for through this same path and the same allowlist. It passes a generated brief
named after the launch intent instead of a task.

## Other hosts

`Spawn` is part of the same host interface that [nudge and reap](seat-nudge.md)
use. Herdr is the only implementation today. Another host needs to open a new
tab or window in a directory with a given environment, run one command in it,
return the new pane's identity, and list the seat workspace's tabs and panes.
