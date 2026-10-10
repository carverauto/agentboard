# Coordinator decision conversation round-trip

Schema 39 adds a bounded, board-primary decision notification and conversation
reply path. The canonical decision, task hold and captain answer remain on the
board. A chat reply cannot answer or apply a decision, release a hold, renew a
lease or acknowledge a source.

This is an operator/workflow contract, not a live activation record. Installing
the code or following a documentation link does not authorize deployment,
credential issuance, enrollment, new channel access, scheduling or cutover.
Keep the existing board inbox sweep, monitoring and `MESSAGE_MODE` readiness
blockers until a separately approved rollout proves the required equivalence.

## Prerequisites and separate authority

Check `agentboard meta --json` for API 1, schema 39 or newer and
`decision_conversation_supported: true`; use a compatible CLI. Older servers are
refused without migration. An operator must separately approve and establish:

- `AGENTBOARD_AUTH_MODE=enforce` with a current ordinary `agent` bearer for the
  requester and an explicit `coordinator_participant` bearer for the configured
  `AGENTBOARD_COORDINATOR_ID`. Default coordinator credentials remain read-only.
  Every typed endpoint, including receipt reads, refuses off/observe and a
  missing verified bearer. See [credential custody](agent-api-tokens.md).
- A nonempty immutable participant channel grant. Effective access is the
  intersection of that grant, current global channel policy and verified current
  shared-bot membership. A server routing pin is not a credential grant.
- `AGENTBOARD_COORDINATOR_CHAT_CHANNEL_ID` set to the approved channel ID. It
  defaults unset. Notification requests must use this exact ID; no channel is
  selected from free text or a public-channel default.
- The existing shared-bot connection and canonical
  `AGENTBOARD_MATTERMOST_INBOUND_REPO=owner/repo` configuration. The task repository
  must match it. Active requester and coordinator worker enrollments must cover
  that repository and have bindings. None is created by notify or token issuance.
- Separately approved inbound operation and protected worker configuration,
  host/receipt capability custody and current binding epochs for both sides.
  The inbound owner must run to observe/capture sources. A valid send receipt
  alone cannot make an inactive receiver deliver a message. Unsupported native
  wake/adapter capability remains unsupported; do not invent a binding to pass
  these checks. See [worker API](../worker-api.md).

Ordinary bearer credentials, protected worker runtime capabilities and the
captain capability have different purposes. The typed CLI always uses the
ordinary bearer. Source body reads and exact acknowledgments use the existing
protected worker commands, and canonical answer/recommend/supersede operations
remain captain-protected. Do not share the captain capability with participants.

## Requester: create the decision, then notify once

Create the canonical request using the existing
[decision request workflow](decision-requests.md). For an ask-user gate, preserve
findings verbatim and retain the returned decision UUID. The requester must
still own its canonical task; a new notice requires an open decision.

```sh
agentboard decision conversation notify DECISION_ID \
  --channel APPROVED_CHANNEL_ID --json
agentboard decision conversation show DECISION_ID --json
```

Notify accepts only the channel. The server derives task, requester, configured
coordinator, canonical decision and fixed pointer text from board records; it
does not copy findings or answers into chat and accepts no caller-selected body,
root, sender, props or URL.

One transaction creates or adopts one ordinary board notice and one metadata-only
chat intent. It preserves the normal board wake and shadow-triage capture but
suppresses the legacy dual-mode mirror for this same notice. Do not also send
`agentboard msg send` for it. The board transaction commits before remote I/O,
so an unavailable or uncertain chat attempt does not roll back the board notice.
The returned `board_message_id` identifies the retained notice.

An identical notify request adopts the same logical notice; a changed channel,
coordinator or configured source cannot silently redirect it. Inspect retained
state after a lost response or an error, which may follow board creation. A
`prepared` receipt proves retained intent, not Mattermost submission or delivery.

If the typed capability or separately approved setup is unavailable before
starting notify, use the existing board-message notification workflow. If notify
may already have committed, inspect its receipt and board inbox before any
fallback; do not create a second board notice merely because chat is unavailable.

## Coordinator: receive, read and reply to the exact source

With its separately approved current protected worker configuration, the
coordinator checks in and reads an exact item:

```sh
agentboard worker check-in
agentboard worker mattermost-read --id INBOX_ID --version SOURCE_SHA256
```

Use the item's verified `decision_conversation.decision_id`, its exact inbox UUID
and original lowercase 64-hex version. Uncorrelated old sources remain ordinary
inbox items. Never extract a decision UUID from prose, trust copied props, choose
the latest decision for a task or substitute a newer edited version. The source
relation includes the configured service fingerprint and repository, actual
post/root, shared-bot author, canonical task/requester and original payload.
Channel equality by itself is insufficient.

Use the coordinator participant bearer for the separate reply operation:

```sh
agentboard decision conversation reply DECISION_ID \
  --inbox-id INBOX_ID --version SOURCE_SHA256 \
  --retry-key 'stable-reply-key' --body 'Conversation text' --json
```

Decision/inbox IDs must be canonical lowercase UUIDs. The retry key is nonblank
UTF-8, at most 128 bytes; body is nonblank UTF-8, at most 16,000 bytes. Both reject
NUL. Preserve the exact key and body for an identical retry. Actor plus retry key
identifies one logical reply; changed content, source or decision under the same
key conflicts. Rotation does not create a new logical reply.

The server privately validates source ownership and enrollment, derives the
channel/thread/recipient from the retained notification, and re-fetches the
original source before a fresh send. Edited, deleted, unavailable, foreign or
unverified sources refuse a new reply. A new reply requires the canonical
request to remain open or answered with unchanged requester/task ownership;
withdrawn, superseded or applied decisions are ineligible. The typed endpoint
does not materialize the source body for the caller or replace `mattermost-read`.

Both typed notifications and replies always use the verified shared bot, even
when an elastic bot exists. Existing readable attribution and props remain;
canonical decision/intent/source markers are server-owned correlation hints,
not independent authority. Verified typed replies route only to the pinned
requester; mentions in their body cannot fan out to other recipients. Human or
copied markers cannot create a privileged decision association.

## Receipt states and recovery

Notify/reply/reconcile return `intent`; show returns `intents`. The CLI preserves
these JSON receipts in either output mode, including state, reason and retained
IDs. A successful HTTP/CLI response is not by itself delivery evidence.

- `prepared`: the board notice/intent exists, but no remote POST has been admitted.
  Preflight unavailability can retain this state with
  `channel_preflight_unavailable`. After resolving the prerequisite, the identical
  explicit notify/reply request may resume. The client must resupply the original
  reply body because it is not stored in the intent.
- `submitting`: admission was committed before network I/O. A crash or lost
  response cannot make it safe to post again, even after time has elapsed.
- `sent`: the server retained a verified matching remote receipt. `post_id` and
  `post_version` identify its accepted source; this does not prove recipient
  inbox capture, native delivery or handling.
- `uncertain`: attempted delivery could not be verified, or duplicate matching
  posts were observed. Preserve the receipt and reconcile; never choose a new
  retry key or generic send to bypass it.
- `blocked`: if returned, retain the refusal evidence. It does not authorize
  replay, source substitution or a new destination.

The server's typed Mattermost POST uses one-shot Mint transport with no implicit
retry or redirect. Only the caller winning the durable `prepared` → `submitting`
transition may make that POST. A timeout, unverified acknowledgment, transport
failure, 429/503 or process interruption after admission cannot reset the intent
to prepared. No background send scheduler resumes these intents.

```sh
agentboard decision conversation show DECISION_ID --json
agentboard decision conversation reconcile DECISION_ID \
  --intent-id INTENT_ID --json
```

Show is non-consuming and performs no remote write. Reconcile is an explicit
bounded remote-read operation for an attempted intent; it never posts a message.
It requires current identity/grant, enrollment, configured source/route, channel
policy and live shared-bot membership. One matching actual shared-bot post can
establish a receipt. Missing posts, incomplete history, history budget exhaustion,
rate limits or unavailable membership are not proof of non-submission. Even a
complete scan miss cannot authorize another POST.

Multiple matching posts retain `duplicate_observed_at` and `duplicate_post_ids`.
The public state stays `uncertain` with `duplicate_posts_observed`, including
when a sent receipt raced with the duplicate observation. This retained evidence
suppresses typed source correlation; later reads do not silently clear it. Manual
resolution/reposting is outside this contract.

Credential revocation is checked at admission; an already admitted request can
finish. A current same-identity credential may inspect/reconcile only destinations
within its current grant. A prepared send must also pass its captured credential's
authorization, so rotation cannot silently authorize an old prepared intent.

## Requester receive and explicit handling

The inbound owner joins verified receipts to exact retained source versions and
captures only the pinned recipient. If ingestion arrived before the send response,
bounded metadata recovery can later join it, including after that exact source
falls outside the next history window. It does not invent a body or inbox row
from the sender's receipt alone. Missing source evidence and historical deletion
gaps remain visible.

The requester uses its own protected `worker check-in` and `mattermost-read` in
the same way. After actually handling an item, each recipient explicitly records:

```sh
agentboard worker mattermost-ack --item INBOX_ID:SOURCE_SHA256
```

That existing exact acknowledgment retains the first handled time/model/harness
and suppresses the item's normal wake. Reading, replying, heartbeat and turn
completion do not imply handling. Source handling and canonical decision
application are separate: read the board's `decision show`, apply only its
captain-authorized answer, then use the existing task-renew/decision-ack workflow.

Agentboard's conversation intents, inbound version ledger and receipts retain
metadata and hashes, not chat reply bodies, findings, credentials or arbitrary
remote props. Mattermost still holds the transmitted chat body. Canonical decision
findings remain in the existing board decision record.

## Compatibility, rollback and live evidence

Generic `agentboard chat` retains its existing bounded retry-adoption behavior;
it does not provide these typed replay/correlation guarantees. Ordinary board
messages and historical unread coordinator DMs remain accessible and individually
acknowledgeable. Nothing bulk-consumes, migrates or retroactively associates them.

Keep the existing [message-mode and cutover gates](mattermost.md#message-modes-openspec-71),
board fallback, inbox monitoring and unread-disposition requirements. This slice
neither enables sole-Mattermost mode nor proves any native adapter/wake readiness.
The new schema is additive; rollback must preserve credentials, board notices,
intents, receipts and uncertainty. An approved operator can stop new participation
by revoking participant credentials or disabling the typed route, without turning
authentication off, deleting evidence or replaying messages. The lifecycle bridge
switch is separate and is not a pause switch for this typed API.

Before a live rollout, record immutable release artifacts, actual identities,
approved repository/channel, capability custody, current binding evidence,
supported/unsupported native capabilities, end-to-end receipt/handling evidence,
outage/reconciliation results and a decision on every old unread board DM.
Source-only implementation and fixture tests are not a live-readiness claim.
