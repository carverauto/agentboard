# Design

## Context

`dual` mode works today: the bridge, private recipient routes, the schema 43
headless chat spool and inbound catch-up all ship. What is missing is behavior
and evidence:
- seats are not told to use chat;
- the coordinator cannot run under farm01's `off` auth;
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

4. **Off and observe verify a presented bearer only on the cutover routes.**
   - `AgentboardWeb.Plugs.AgentAuth` is the assignment point.
     `CoordinatorController` and `DecisionConversationController` read
     `authenticated_agent` and do not build a principal themselves.
   - Under `off` and `observe`, a presented bearer is verified and assigned
     for the four protocol operations (heartbeat, acknowledge, GET tick and
     GET show) and for decision-conversation notify and reply. Observe's skip
     of GET, HEAD and OPTIONS does not apply to tick or show.
   - No bearer leaves the caller anonymous. A missing, invalid or revoked
     bearer fails closed and assigns nothing.
   - This verification path is not added to decision-conversation show,
     reconcile, or any other route. Those routes keep their current
     authentication.
   - The protocol operations then accept that principal when it is the
     `coordinator_runner` for the active coordinator. Notify still requires
     `agent`. Reply still requires `coordinator_participant`. The domain
     checks that today require auth `enforce` accept these assigned
     principals under `off` and `observe` for those operations only. The
     runner bearer does not authorize notify or reply.
   - Rejected alternative: flip farm01 to `enforce`. It is global and breaks
     every anonymous seat CLI.
   - Rejected alternative: let the captain capability stand in. The protocol
     explicitly forbids that substitution.
   - Rejected alternative: widen only the domain `enforced` check. Under `off`
     the plug never assigns `authenticated_agent`, so the domain still sees
     nil.

5. **The Herdr seat delivery adapter is seat nudge, not a new daemon.**
   - Nudge already reads Herdr state and board work every three minutes.
   - It gains a host-scoped unread count per seat: coordination-channel
     mentions of the seat's ID, and private-route items for that seat. The
     count returns counts only. It does not return message content, advance
     `conversation_coverage`, or mark anything read.
   - `chat read` stays the owning agent's path and still records that agent's
     coverage. The host does not call it as the seat.
   - Readiness comes from a recent nudge pass that covered every live fleet
     seat, reported to the server as a heartbeat-like receipt.
   - Rejected alternative: per-harness native adapters. Five harnesses differ,
     and Herdr is the common surface.
   - Rejected alternative: widen `chat read` so the host can impersonate a
     seat. That consumes the seat's coverage before the seat sees the post.

6. **Decision-path readiness is measured by a round-trip.**
   - Coordinator liveness (protocol heartbeat within the staleness window) is
     one half.
   - The other half is one retained decision-conversation notify/reply receipt.
     The receipt is not compared to the runner credential. Rotating the runner
     leaves a retained receipt valid.
   - Notify and reply run on the principal decision 4 assigns. Show and
     reconcile keep their current authentication. Anonymous and wrong-scope
     callers still fail closed.
   - Captain answers still go through `decision answer`, whose authority is
     captain or coordinator plus the captain capability. Chat replies never
     answer a decision.

7. **Legacy unread disposition is explicit, never bulk.**
   - The drain lists every unread board DM grouped by recipient.
   - Each disposition is one record keyed by board message id, attributed to
     the captain: `handled`, `forwarded` (private-route receipt id included),
     or `kept`. The record is stored apart from message acknowledgement.
   - Recording a disposition does not acknowledge the message. An
     acknowledgement does not write a disposition.
   - `handled` and `kept` leave the direct message unread and acknowledgeable
     on the 7.2 historical path. `kept` is allowed for ordinary seats.
   - `forwarded` posts to the recipient's private route, stores the receipt on
     the disposition record, and leaves acknowledgement as a separate
     recipient action.
   - The blocker clears when every unread captain or coordinator DM has a
     disposition record. A `kept` or `handled` record clears that unread
     message without acknowledging it.
   - Rejected alternative: automatic acknowledgement at cutover. It silently
     loses decisions, which is issue #80's failure.
   - Rejected alternative: treat acknowledgement as the disposition. `kept`
     would then have to ack the message to clear the gate.

8. **No new message tables are dropped.**
   - `/messages` stays the read-only archive with export (7.2).
   - The only new table is the disposition record in decision 7.
   - Rollback is the existing mode restart.

9. **A refused `mattermost` request is effective `dual`.**
   - Dual has no activation gate. Requested `dual` stays effective `dual`
     with bridge, private-route or inbound blockers still set, and a refused
     `mattermost` request uses that same effective mode.
   - Nothing stores a last accepted mode.
   - Mirroring follows effective mode, including the `dual?` check that today
     reads only the requested env value.
   - An invalid requested mode stays `board`.

## Risks

- The shared bot posts with `override_username`. Mattermost v12 may stop
  honoring it. The header line and props keep attribution, and
  mm-elastic-agent-bots stays the fix.
- Seats that ignore the brief still use legacy sends until cutover refuses them
  with `message_transport_migrated`. That refusal is the backstop.
