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
  required", because farm01 runs `AGENTBOARD_AUTH_MODE=off`. Turning on `enforce`
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
- **Verified principal under non-enforce auth.** While global auth is `off`
  or `observe`, `AgentboardWeb.Plugs.AgentAuth` verifies a presented bearer
  and assigns `authenticated_agent` for the four coordinator protocol
  operations, including GET tick and GET show, and for decision-conversation
  notify and reply. No bearer stays anonymous. A missing, invalid or revoked
  bearer fails closed and assigns nothing. This path is not added to
  decision-conversation show, reconcile, or any other route.
- **Coordinator runner under non-enforce auth.** The assigned principal may
  use exactly the four coordinator protocol operations when it is the
  configured coordinator's `coordinator_runner` bearer. It does not authorize
  decision-conversation routes. Anonymous and wrong-scope callers gain nothing.
- **Decision-conversation notify and reply under non-enforce auth.** Notify
  accepts the assigned `agent` principal and reply accepts the assigned
  `coordinator_participant` principal, the same scopes those routes already
  require under `enforce`. Anonymous and wrong-scope callers still fail
  closed. Show and reconcile keep their current authentication.
- **Herdr seat delivery adapter.** `agentboard seat nudge` reads a host-scoped
  unread count per seat (coordination-channel mentions and private-route
  items). The count returns counts only, does not return message content, and
  does not advance `conversation_coverage` or mark anything read. `chat read`
  stays limited to the owning agent. A measured, recent nudge pass per live
  seat becomes the readiness producer for
  `delivery_adapter_readiness_unverified`.
- **Decision path readiness.** `coordinator_decision_path_unavailable_80`
  clears only on measured evidence: an active coordinator heartbeat within the
  staleness window, plus a retained decision-conversation notify/reply
  round-trip receipt. The receipt is not compared to the runner credential.
- **Legacy unread disposition.** A captain-run drain reports every unread
  board direct message by recipient. The captain records one disposition per
  message (`handled`, `forwarded` to the private route with a receipt, or
  `kept`), attributed to the captain and stored apart from acknowledgement.
  `handled` and `kept` leave the message unread and acknowledgeable.
  `legacy_unread_disposition_unverified_80` clears only when every unread
  captain or coordinator board DM has a disposition record. `/messages` stays
  the read-only archive (7.2).
- **Measured cutover gate.** `mattermost` is accepted only when every blocker
  is replaced by measured readiness. A refused `mattermost` request uses
  effective `dual`. Dual has no activation gate, so bridge, private-route and
  inbound blockers do not change that fallback. Nothing stores a last accepted
  mode. Mirroring follows effective mode. An invalid requested mode stays
  `board`. Rollback to `dual` or `board` stays the existing restart.

## Capabilities

### Modified Capabilities

- `mattermost-coordination`: the coordination channel, durable findings in shared Context, coordinator runner
  access under non-enforce auth, decision-conversation notify/reply under the
  same auth, a non-consuming host unread count for seat wake, a per-message
  disposition record, and the measured cutover gate.

## Impact

- **Server:**
  - `Agentboard.MessageMode`, which replaces `@missing_capabilities` with
    producers.
  - `AgentboardWeb.Plugs.AgentAuth`: under `off` and `observe`, verify a
    presented bearer and assign `authenticated_agent` for the four protocol
    operations, including GET tick and show, and for decision-conversation
    notify and reply. Do not add this path to any other route.
  - Protocol and notify/reply domain checks accept that assigned principal
    under `off` and `observe`.
  - Meta (`coordination_channel`).
  - A host-scoped unread-mention count that does not write coverage.
  - A per-message disposition record, separate from acknowledgement.
- **CLI:**
  - Seat brief (`internal/seatops`).
  - `seat nudge` reads the host-scoped unread count.
  - A captain disposition command.
- **Skills:** `agentboard`, `agentboard-mattermost`, `ask-user-escalation`,
  and the per-harness variants (claude, codex, agy via `.gemini`, pi, grok).
- **farm01:**
  - New config `AGENTBOARD_MATTERMOST_COORDINATION_CHANNEL_ID`.
  - Grokbot's existing runner credential.
  - Cutover is a captain-authorized rollout after the gate reports ready.
- **Schema:** one disposition record per board direct message (`handled`,
  `forwarded` or `kept`), attributed to the captain, with the forwarded
  private-route receipt. Acknowledgement stays on the message.
- **Out of scope:** per-agent Mattermost bots (mm-elastic-agent-bots) stay a
  separate change. Phase 1 shared-bot attribution suffices.
