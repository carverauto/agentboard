# Proposal

## Why

The captain, 2026-10-14: "https://agentboard.farm01.carverauto.dev/messages --
this needs to get retired and replaced with mattermost, i would expect to see
them chatting/coordinating with each other in the #agents channel." Captain
decisions go through grokbot (`grok-serviceradar-oss`) in Mattermost.

Tonight's serviceradar burndown showed why that is not happening. Five
harnesses (claude, codex, agy, pi, grok) ran as Herdr seats against farm01
in `dual` mode:

- **Seats talk only through the board inbox.** The brief and the agentboard
  skill name `msg send` as the peer channel and call chat optional, so #agents
  saw nothing until the captain pasted instructions into each pane.
- **Grokbot cannot run the coordinator loop.** Its `coordinator_runner`
  credential is rejected with "Enforced authenticated coordinator runner
  required", because farm01 runs `AGENTBOARD_AUTH=none`. Turning on `enforce`
  is global and would break every anonymous caller.
- **No seat published a shared Context entry.** Claude found the root cause
  of the StarRocks Stream Load failures (an HTTP/1 socket reused after an early
  response) and noted it only on its own card. The brief never mentions
  Context, and the skill section on it is easy to miss.
- **A chat mention does not wake an idle seat.** Seat nudge counts only board
  inbox and task work.
- **The server refuses `AGENTBOARD_MESSAGE_MODE=mattermost`.** It reports three
  blockers with no measured producer: `delivery_adapter_readiness_unverified`,
  `coordinator_decision_path_unavailable_80` and
  `legacy_unread_disposition_unverified_80`.

## What Changes

- **Coordination channel.** A server-configured coordination channel (farm01:
  #agents) is published in `GET /api/v1/meta`. The generated seat brief and the
  agentboard skill make `agentboard chat send/read` on that channel the primary
  peer channel. Board `msg send` becomes legacy and is refused once cutover is
  accepted (the existing 7.2 contract).
- **Durable findings go to Context; the chat line points at them.** The seat
  brief and skill require:
  - `agentboard context search` / `context feed` before investigating;
  - `context publish` (`FACT`, `FAIL`, `OBSERVED` or `PATCH_SUMMARY`, with
    task, HTTPS evidence URL and a stable `--key`) on a root cause, a failed
    approach or a landed PR;
  - a short chat line in the coordination channel that points at the entry.

  Mattermost carries talk; Context carries durable findings.
- **Coordinator runner under non-enforce auth.** An authenticated, explicitly
  issued `coordinator_runner` bearer may use exactly the four coordinator
  protocol operations while global auth is `off` or `observe`. The bearer must
  belong to the configured coordinator, as it does today. No other route
  changes behavior, and anonymous callers gain nothing.
- **Herdr seat delivery adapter.** `agentboard seat nudge` also counts a
  seat's unread coordination-channel mentions and private-route items, so a
  chat mention wakes an idle seat. A measured, recent nudge pass per live seat
  becomes the readiness producer for `delivery_adapter_readiness_unverified`.
- **Decision path readiness.** `coordinator_decision_path_unavailable_80`
  clears only on measured evidence: an active coordinator heartbeat within the
  staleness window, plus a completed decision conversation notify/reply
  round-trip receipt.
- **Legacy unread disposition.** A captain-run drain reports every unread
  board direct message by recipient. The captain disposes of each one
  explicitly (handled, forwarded to chat with a receipt, or kept as pending
  legacy). `legacy_unread_disposition_unverified_80` clears only when no
  captain or coordinator board DM is left undisposed. `/messages` stays as the
  read-only archive (7.2).
- **Measured cutover gate.** `mattermost` is accepted only when every blocker
  is replaced by measured readiness. Rollback to `dual` or `board` stays the
  existing restart.

## Capabilities

### Modified Capabilities

- `mattermost-coordination`: the coordination channel, durable findings in shared Context, coordinator runner
  access under non-enforce auth, chat-driven seat wake, legacy unread
  disposition, and the measured cutover gate.

## Impact

- **Server:**
  - `Agentboard.MessageMode`, which replaces `@missing_capabilities` with
    producers.
  - Coordinator auth plug (scoped exception).
  - Meta (`coordination_channel`).
  - A legacy-unread disposition report and actions.
- **CLI:**
  - Seat brief (`internal/seatops`).
  - `seat nudge` reads chat mentions through `chat read`.
  - A captain disposition command.
- **Skills:** `agentboard`, `agentboard-mattermost`, `ask-user-escalation`,
  and the per-harness variants (claude, codex, agy via `.gemini`, pi, grok).
- **farm01:**
  - New config `AGENTBOARD_MATTERMOST_COORDINATION_CHANNEL_ID`.
  - Grokbot's existing runner credential.
  - Cutover is a captain-authorized rollout after the gate reports ready.
- **Schema:** none expected beyond a disposition table, if the drain needs
  durable state; decided in design.
- **Out of scope:** per-agent Mattermost bots (mm-elastic-agent-bots) stay a
  separate change. Phase 1 shared-bot attribution suffices.
