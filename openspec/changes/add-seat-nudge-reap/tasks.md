# Tasks

## 1. Nudge

- [x] 1.1 Add `internal/seatops` with host/board interfaces, Herdr CLI host, config, locked atomic state, discovery and the nudge decision; cover discovery, busy/waiting/idle cases, card picking, recheck aborts, dedupe, rate limit, uncertain send, kill switch and lock in unit tests.
- [x] 1.2 Add `agentboard seat nudge` over the paged HTTP board; verify end to end against a fake Herdr binary and a paged fake board.
- [x] 1.3 Name the Herdr pane on `agent register --backend herdr`; verify with a fake Herdr binary.

## 2. Reap

- [x] 2.1 Add reap with a shared landed gate (also used by `seat return`), pane recheck, optional Treehouse lease return and report-only expired claims and retire candidates; cover keep/close/return cases with real Git checkouts.

## 3. Delivery

- [x] 3.1 Setup guide, launchd/systemd templates, Herdr skill and worker-runtime doc updates.
- [x] 3.2 Remote Bazel tests and a dry run of both commands against the live board.
- [ ] 3.3 Idle-wake pilot: one coordinator and two Herdr seats complete a bounded task woken only by `seat nudge --apply`.
