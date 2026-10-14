# Nudge idle seats and reap finished ones

`agentboard seat nudge` wakes Herdr-hosted seats that are idle while the board
has work for them. `agentboard seat reap` closes seats that have finished. Both
run on the machine that hosts the Herdr server, usually from a 3-minute launchd
or systemd timer. Neither writes to the board.
To start a new seat in its own Herdr tab, see
[spawn a seat](seat-spawn.md).

## How a seat is found

A Herdr agent pane is a seat when its Herdr name equals a board agent ID,
exactly one pane has that name, and the Herdr agent kind (`codex`, `claude`,
`muse`, …) equals the identity's registered harness. A seat names its own pane
when it registers from inside Herdr:

```sh
agentboard agent register --backend herdr --json
# does the same as:
herdr agent rename "$HERDR_PANE_ID" "$AGENT_ID"
```

That rename needs `HERDR_PANE_ID`. [Seat supply](fleet-host.md) names a launched
pane after the seat's agent ID once Herdr detects the harness, which covers a
shell that never received the variable.

Panes with no name are ignored. Duplicate names, harness mismatches and
allow/deny scope exclusions are listed as skipped and never touched. Retired
identities are skipped by the nudge; reap may still close the pane a retired
identity still occupies when it is otherwise finished.

## Nudge

For each seat the nudge reads the Herdr status and the last terminal lines, the
seat's open tasks, unread messages and availability. It prompts only an idle
seat, and only with a reason:

| Seat | Prompted when |
| --- | --- |
| Idle | It has unread messages, an expired claim on in-progress work, a higher-priority task than its current work, or it has idled past `idle_after` (default 20m) with in-progress work |
| Waiting on the captain/coordinator (an owned blocked/review task whose last note says so, or a matching question on screen) | A message arrived after it started waiting. It is never pointed at new work |
| Busy, approval prompt open, unknown status, or availability not `active` | Never |

The prompt names the reason and asks the seat to run its agentboard check-in. It
grants nothing: the seat re-reads the board and acts on what it finds there, so
a prompt that arrives late or twice costs one turn and nothing else.

The same reason set is never sent twice, and one seat is prompted at most once
per `min_gap` (default 15m). Immediately before sending, the nudge re-reads the
pane and aborts if the pane name, native session ID, agent kind or Herdr state
sequence changed since it decided, if the seat left idle/done, or if its
screen turned busy. Herdr 0.9.0 has no conditional prompt, so a
small window remains between that recheck and the prompt; the content-free
prompt is what keeps losing that race harmless. A send whose outcome is unknown
is recorded and not replayed.

## Reap

Reap closes a seat's Herdr pane only when all of these hold:

- Herdr reports it idle and its screen is not busy, continuously for
  `reap_after` (default 30m)
- it owns no assigned, open, in-progress, blocked or review task
- it has no unread message
- its working directory has landed: a clean Git tree whose HEAD is on a remote
  branch or `origin/main` (an unknown working directory counts as not landed)
- its availability is unset or `active`; any other availability state keeps
  the pane, and keeps its lease

It re-reads the pane before closing and leaves it alone if the pane name,
native session, agent kind, state sequence or idle/done status changed, or its
screen turned busy.
With `treehouse_roots` configured it also returns Treehouse leases whose holder
has no live pane, owns no open task, has no process in the worktree, and whose
work has landed. Each repository pool under a root is listed from one of its
own worktrees, so the timer's working directory does not matter. Without
`treehouse_roots`, pools are never read; any Git checkout works for the pane
gate.

Reap never releases a claim or retires an identity. It reports expired claims
whose owner has no live pane and identities with no pane and no open task, so a
captain can reclaim, hand off or retire them explicitly.

## Dry run first

Both commands are dry runs unless given `--apply`:

```sh
agentboard seat nudge          # what would be sent, and why
agentboard seat reap           # what would be closed or returned, and what is reported
agentboard seat nudge --json   # bounded JSON report
```

## Configuration

`~/.config/agentboard/seat/config.json` is optional; every field has a default.
It must be owned by you and not group/world writable.

```json
{
  "version": 1,
  "allow": [],
  "deny": ["codex-reserved-seat", "w4P"],
  "min_gap": "15m",
  "idle_after": "20m",
  "reap_after": "30m",
  "treehouse_roots": ["/path/to/agentboard-seats-v3"],
  "state_file": "~/.local/state/agentboard/seat-ops.json",
  "kill_switch": "~/.config/agentboard/seat/off"
}
```

`allow`, when non-empty, limits both commands to those agent IDs. `deny` takes
agent IDs or Herdr workspace IDs. For a seat that should stay up but receive no
prompts, prefer a board availability policy (`agentboard agent availability`),
which every host honours. Create the kill switch file to stop both commands
immediately; delete it to resume.

## Schedule

Fill in the templates and load one:

- macOS: [`contrib/launchd/dev.agentboard.seat-ops.plist`](../../contrib/launchd/dev.agentboard.seat-ops.plist)
  → `~/Library/LaunchAgents/`, then `launchctl load ~/Library/LaunchAgents/dev.agentboard.seat-ops.plist`
- Linux: [`contrib/systemd/agentboard-seat-ops.service`](../../contrib/systemd/agentboard-seat-ops.service)
  and `.timer` → `~/.config/systemd/user/`, then
  `systemctl --user enable --now agentboard-seat-ops.timer`

A run that finds another run still holding the state lock skips. The job needs
the same board read access as any CLI read (`AGENTBOARD_URL`, plus your token or
access file if the board requires one).

## Other hosts

The nudge, reap and [spawn](seat-spawn.md) logic talks to the host through a
small interface: list agents with a status, a name and a native session ID;
read recent output; prompt; close; name a detected agent; open a new tab that
runs one command. Herdr is the only implementation today. Another terminal or
desktop host can be added by implementing that interface. The method list lives
on `Host` in `internal/seatops/herdr.go`.
