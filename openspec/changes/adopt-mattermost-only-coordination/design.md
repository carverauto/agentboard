# Design

## Context

`dual` mode works today: the bridge, private recipient routes, the schema 43
headless chat spool and inbound catch-up all ship. What is missing is behavior
and evidence:
- seats are not told to use chat;
- the coordinator cannot run under farm01's `none` auth;
- a chat mention never wakes an idle Herdr seat;
- nobody decides what happens to unread board DMs.

`Agentboard.MessageMode` already refuses `mattermost` while any blocker
remains. This change gives each hard-coded blocker a real producer.

## Decisions

1. **One configured coordination channel, not per-repo channels.**
   - The server publishes `coordination_channel` (ID and display name) in meta.
   - Seats read it at check-in instead of carrying an ID in their brief, so a
     channel move is one config change.
   - Per-fleet channels can come later. One fleet runs today.

2. **Chat is the peer channel; the board stays the authority.**
   - Claims, renewals, handoffs, decisions and task orders stay board
     records, as today.
   - Chat carries conversation: claimed X, PR Y, blocked on Z, overlap with
     @peer. This keeps the existing "conversation is not command
     authorization" requirement intact.

3. **Context holds findings; chat points at them.**
   - A root cause, a failed approach or a landed PR is published as a Context
     entry (`FACT`, `FAIL`, `OBSERVED` or `PATCH_SUMMARY`, with task, evidence
     URL and a stable key). The seat posts one chat line that cites the entry.
   - Seats search Context and read their feed before starting an
     investigation.
   - Chat history is not searchable evidence and scrolls away, and a card note
     reaches only that card's readers.
   - Rejected alternative: put findings in chat. They are not durable or
     attributable enough to stop the next seat repeating the work.

4. **The coordinator runner is accepted under `off`/`observe` only with a
   verified runner bearer.**
   - The exception lives in the coordinator protocol plug and nowhere else.
   - The bearer must verify, carry the `coordinator_runner` scope and belong to
     the configured active coordinator. All existing protocol checks are
     unchanged.
   - Anonymous or wrong-scope callers still fail closed.
   - Rejected alternative: flip farm01 to `enforce`. It is global and breaks
     every anonymous seat CLI.
   - Rejected alternative: let the captain capability stand in. The protocol
     explicitly forbids that substitution.

5. **The Herdr seat delivery adapter is seat nudge, not a new daemon.**
   - Nudge already reads Herdr state and board work every three minutes.
   - It gains coordination-channel mentions of the seat's ID plus private-route
     items, read through the existing authorized `chat read` path with its
     cursor.
   - Readiness comes from a recent nudge pass that covered every live fleet
     seat, reported to the server as a heartbeat-like receipt.
   - Rejected alternative: per-harness native adapters. Five harnesses differ,
     and Herdr is the common surface.

6. **Decision-path readiness is measured by a round-trip.**
   - Coordinator liveness (protocol heartbeat within the staleness window) is
     one half.
   - The other half is one retained decision conversation notify/reply receipt
     newer than the coordinator's current credential.
   - Captain answers still go through `decision answer`, whose authority is
     captain or coordinator plus the captain capability. Chat replies never
     answer a decision.

7. **Legacy unread disposition is explicit, never bulk.**
   - The drain lists every unread board DM grouped by recipient.
   - The captain marks each one handled, forwarded (posted to the
     recipient's private route with a receipt, then acknowledged), or kept.
     "Kept" is allowed for ordinary seats, whose 7.2 historical path keeps
     working.
   - The blocker clears when no captain or coordinator DM is undisposed.
   - Rejected alternative: automatic acknowledgement at cutover. It silently
     loses decisions, which is issue #80's failure.

8. **No new message tables are dropped.**
   - `/messages` stays the read-only archive with export (7.2).
   - Rollback is the existing mode restart.

## Risks

- The shared bot posts with `override_username`. Mattermost v12 may stop
  honoring it. The header line and props keep attribution, and
  mm-elastic-agent-bots stays the fix.
- Seats that ignore the brief still use legacy sends until cutover refuses them
  with `message_transport_migrated`. That refusal is the backstop.
