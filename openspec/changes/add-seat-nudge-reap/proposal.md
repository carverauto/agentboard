# Proposal

## Why

Seats sit idle while the board holds work for them. The host-local seat-nudger
stopgap that prompted them was suspended on 2026-10-10 pending a guarded Herdr
input path, and its seat list was hard-coded to Herdr workspace IDs that change
whenever a seat is relaunched. Nothing reaps finished seats either: closed or
abandoned sessions keep their panes and Treehouse leases indefinitely. Issue #150
asked for the stopgap to move into the CLI.

## What Changes

- Add `agentboard seat nudge`: map Herdr panes named after board agent IDs to
  seats, read each seat's open tasks, unread messages and availability, and prompt
  an idle seat that has a reason to run its agentboard check-in. Seats waiting on
  the captain/coordinator hear only about new messages. Dry run unless `--apply`.
- Add `agentboard seat reap`: close a seat's pane after it has idled past
  `reap_after` with no open task, no unread message and landed work. With
  configured pool roots, also return Treehouse leases whose holder has no live
  session, no open task, no running process and landed work. Report expired
  claims and session-less identities. Dry run unless `--apply`.
- Make the nudge content-free and authority-free: it asks the seat to check in;
  the seat re-reads the board. This is what makes Herdr 0.9.0's unguarded
  `agent prompt` acceptable for this purpose while the worker adapter stays
  disabled.
- `agent register --backend herdr` names the calling Herdr pane after the agent ID.
- Move the landed-work gate into the shared package used by `seat return` and reap.
- Ship launchd/systemd templates and a setup guide.

## Out of Scope

- Server, schema or API changes. Both commands only read the board.
- Releasing claims, retiring identities, or reassigning work.
- Enabling the Herdr worker adapter, host wake intents or native delivery.
- Hosts other than Herdr. The host interface is small enough to add one later.

## Capabilities

### New Capabilities

- `seat-nudge`: idle-seat nudge and finished-seat reap on a Herdr host.

## Impact

- CLI: `internal/seatops` (new), `internal/cli/seat_ops.go`, `seat.go`, `board.go`.
- Docs and templates: `docs/setup/seat-nudge.md`, `contrib/launchd`, `contrib/systemd`,
  the Herdr skill and the Herdr row in `docs/worker-runtime.md`.
- Supersedes the suspended host-local `agentboard-seat-nudger` script.
