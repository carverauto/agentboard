# Design

## Seat identity

A pane is a seat only when its Herdr name equals a non-retired board agent ID,
exactly one pane carries that name, and the Herdr agent kind equals the
identity's harness. The name is set by the seat itself at registration. This
replaces the stopgap's hard-coded workspace table, which broke on every relaunch.

## Why a content-free prompt is safe on Herdr 0.9.0

Herdr 0.9.0 `agent prompt` has no expected-recipient or empty-composer guard,
which is why the worker adapter remains disabled: a frozen, receipt-bearing
delivery cannot be fenced. A nudge carries nothing to fence. It names a reason and
asks for a normal check-in; the seat re-reads every fact from the board under its
own identity. Duplicate, late or misdirected prompts therefore cost a turn but
cannot cause an unauthorized action.

The nudge still narrows the window. It re-reads the pane immediately before
sending and aborts if the name, native session ID, agent kind or Herdr
`state_change_seq` differs from the snapshot it decided on, or the screen shows
work in progress. Herdr's own `agent_blocked` rejection is retried later; any
other send error is recorded as uncertain and never replayed.

## Deduplication and pacing

Each nudge hashes its reason set. The same set is never sent twice, and a seat is
prompted at most once per `min_gap`. State lives in one host-local file, written
atomically under an exclusive lock that also makes overlapping timer runs skip.
Timestamps reset when a pane's native session changes.

## Reap safety

Closing a pane can destroy uncommitted work, so the gate is conjunctive: idle for
`reap_after`, no open task, no unread message, a clean tree, and HEAD on a remote
branch or `origin/main`. The pane is re-read before closing. Lease return
additionally requires no process in the worktree and uses `treehouse return
--if-lease-holder`. Claims and identities are only reported: the existing contract
says an expired claim alone does not authorize takeover.

## Treehouse and other hosts

Nudge never reads Treehouse. Reap's pane gate works for any Git checkout; lease
return runs only for explicitly configured pool roots. The host is a five-method
interface (list, get, read, prompt, close) so another terminal or desktop host can
be added without touching the decision logic.
