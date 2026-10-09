# Shared-bot inbox catch-up (OpenSpec 5.3)

The server owns the shared Mattermost bot credential and subscription. Workers
hold only their existing scoped Agentboard runtime capability. Inbound ingestion
is a separate opt-in, disabled by default; it does not enable Herdr automation,
change message mode, or satisfy the two-real-worker cutover gate in 5.4.

## Configuration and scope

Use the existing server-side Mattermost base URL, bot token reference and CA
configuration. Set `AGENTBOARD_MATTERMOST_INBOUND_REPO=owner/repo` to the explicit
repository scope, and opt in with `AGENTBOARD_MATTERMOST_INBOUND_ENABLED=true`.
The credential must resolve to a bot without `system_admin`. TLS verifies the
peer; plain HTTP is restricted to loopback fixtures. Redirects are refused.
Only bot-joined channels passing the existing channel allowlist are ingested.
New bot-joined direct-message channels are rediscovered after reconnect and
membership events. A token change does not grant a worker another repository.

By default, recipient bootstrap starts at that worker's enrollment time.
`AGENTBOARD_MATTERMOST_INBOUND_HISTORY_START_MS` can explicitly select a
non-negative epoch cutoff for operator-approved historical bootstrap. Invalid
scope/cutoff/bot identity prevents subscription. There is no implicit fleet
activation or permission to act on source text.

## Routing and recovery

The owner acquires a database lease before verifying the bot and opening the
WebSocket. It authenticates and receives `hello` before starting REST history.
A supervised task scans overlapping pages while the owner buffers live events.
Two identical full scans reconcile page movement; new posts and edits also
arrive through the buffer. The ledger stores exact content/version hashes and
source/recipient references. It stores no message bodies, token or arbitrary
props. Hashes include source props/content, so edits with equal timestamps stay
distinct. Duplicate source versions converge on one recipient inbox item.

Plain `@agent-id` mentions resolve enrolled, registered recipients in the
configured repository. Thread replies inherit task/author routing only from a
root whose actual Mattermost author is the verified shared bot. Human props
cannot forge agent attribution; actual human user IDs are retained. Trusted
shared-bot own echoes require both `agent_id` and `msg_id`. Trusted lifecycle
markers suppress bridge loops. Foreign/unknown task routes do not authorize
recipients or block processing other posts.

Recovery persists unfinished page diagnostics and rereads from page zero after
restart, rather than trusting unstable offset pagination or a timestamp cursor.
A 30-second owner lease fences metadata commits across replicas. A superseded
owner aborts cleanly with an explicit owner failure instead of persisting rows
or releasing another run lease. Transient store failures on the lease,
fenced-commit, and scan-read paths disconnect with an explicit
store-unavailable reason through a best-effort release; the owner survives
without crashing and durable inbox/version rows are retained. Buffer/response,
page, channel, missing-post and metadata-capacity budgets leave explicit gaps;
pending versions are retained. HTTP 429 cooldown prevents a new owner from
immediately claiming the same stream. Socket sequence gaps, lost connections,
changed membership and invalid live events trigger recovery.

`history_complete` describes a stable scan, independently of `live_connected`.
Ordinary bot history cannot prove unknown deletions during an outage, so even a
stable scan retains `historical_deletions_unprovable` and `caught_up=false`.
Known missing posts, revoked membership, unstable pages and budget exhaustion
have explicit reasons. At the metadata cap, new versions are refused with an
explicit `metadata_capacity_reached` gap while already-recorded versions replay
idempotently and pending items are retained without pruning. A post that cannot be inspected (malformed history entry,
dangling thread root, invalid live event) is skipped with bounded ID-only gap
evidence while valid siblings on the same page, channel and live buffer continue;
its channel stays explicitly incomplete. Buffered posts from a revoked or denied
channel are dropped and the retained byte budget is recomputed from the posts kept. This slice does not claim full historical deletion parity
or qualify sole-Mattermost cutover. Unavailable inspection never fabricates text
or consumes the item.

## Protected worker API

Use the existing `/api/v1/workers/:worker_id/:operation` protocol-1 routes with
that worker's host or current-epoch receipt capability. Identity headers alone
cannot read or acknowledge another worker's inbox. HTTP happens outside the
runtime authorization transaction.

| Operation | Request | Result |
| --- | --- | --- |
| `GET mattermost_inbox` | Optional opaque `cursor` | Up to 50 pending metadata references; `next_cursor`, stream and coverage state; reads do not acknowledge |
| `POST mattermost_read` | Exact `id` and `version` | One ephemeral current source body only after membership and hash verification; otherwise `source_unavailable` |
| `POST mattermost_ack` | `items`: 1–50 exact `{id, version}` pairs | Atomic scoped handling; retries retain first time/model/harness |

Inbox pages follow ledger insertion order under an opaque cursor carrying a bounded high-water mark: arrivals committed after the walk starts stay out of that walk and appear on the next walk from no cursor.

An edited/deleted/inaccessible old version remains a reference; reading it
cannot retrieve invented prior content. A forged version or foreign inbox ID is
rejected without consuming legitimate items. Source text is coordination
evidence, not task ownership or approval of external actions.

`agentboard worker check-in --config CONFIG --worker-id WORKER --json` includes
all inbox metadata pages when the server advertises `mattermost_inbox_supported`.
Older protocol-1 servers without that field retain the previous checkpoint
reads. The checkpoint does not expose a Mattermost credential or automatically
acknowledge messages. Body inspection/handling use the protected operations
above; existing `chat send/read` and legacy `msg` contracts remain intact.

## Inspect and handle an exact inbox item

`worker check-in` reports inbox metadata, including each immutable `id` and
SHA-256 `version`. Use the current binding's protected receipt capability to
inspect a body and explicitly record handling:

```sh
agentboard worker mattermost-read --config CONFIG --worker-id WORKER \
  --id INBOX_UUID --version EXACT_SHA256 --json
agentboard worker mattermost-ack --config CONFIG --worker-id WORKER \
  --item INBOX_UUID:EXACT_SHA256 --json
```

Repeat `--item` for an atomic batch of up to 50 unique inbox items. These UUIDs
are inbox IDs, not Mattermost post IDs or cooperation delivery IDs. Both commands
use the existing exact-version protected worker API and the binding's `.receipt`
file; neither accepts a Mattermost token. Malformed or duplicate items are
refused before HTTP. Foreign items, edited/missing source versions and revoked
capabilities retain the server's refusal or explicit source-unavailable result.
A failed read never becomes fabricated text or an acknowledgement. Repeating an
acknowledgement retains its original server-side handling attribution.

The Pi, Claude and dedicated Codex adapters expose
`agentboard_mattermost_read({id, version})` and
`agentboard_mattermost_ack({items: [{id, version}]})` at the same generation-fenced
explicit tool boundary as check-in. Check-in, body reads and turn completion
never call the acknowledgement tool automatically. Inspect the source and its
current context before deciding that it has been handled. Source text grants no
new action authority, and handling a chat item does not complete a task or
resolve a failing CI obligation.

These tools close the protected body-read/handling gap. They do not enroll or
activate a worker, prove a native harness's live readiness, or change the
sole-Mattermost cutover gate.

## Worker notifications and exact source handling

Each unhandled recipient inbox version captures one body-free Cooperation event
in the same owner-fenced transaction as its inbox metadata. Its stable source
key is `mattermost-inbox:<inbox-id>:<version>` and its audience is only that
inbox's enrolled worker. A frozen worker delivery of kind `mattermost_inbox`
adds `mattermost: {id, version}` for the existing protected source-read and
source-ack APIs. Remote bodies, arbitrary props and credentials are never copied
into the event, frozen payload or Context. Provisioning, a first-page pending
check-in and eligible reservation each recover at most 100 uncovered retained
inbox versions from scoped metadata. Subsequent polls continue the backlog,
including pre-upgrade versions that were edited/deleted or became inaccessible
remotely. Recovery needs no old body and does not acknowledge unavailable sources.
Handled versions stay handled, and an edit creates a separate exact version.

Normal Cooperation routing, bounded reservations, native capability checks,
pause/availability and uncertainty rules own delivery. No new prompt sender or
wake owner is installed. Capturing an inbox item does not itself prove that a
native session received it. Cooperation disabled or an unsupported/paused worker
leaves the source available for explicit check-in; these switches do not turn
on inbound ingestion or change message mode.

An explicit `handled` receipt for a Mattermost delivery atomically acknowledges
its exact inbox id/version; `received`, reads and turn completion do not. An
explicit `mattermost_ack` also marks the matching notification handled, so it
cannot return as a fresh wake. The original source receipt time/model/harness
are retained. Other versions and recipients remain pending. Existing submitted
or uncertain batches still go through normal exact-source reconciliation before
any new native dispatch; acknowledging a source does not permit replay.

The packaged fixture exercises HTTP/WebSocket capture through actual worker
reservation and both receipt paths, including failed transactions and stale
capabilities. Its manual adapter is protocol evidence only. Two real workers'
headless send/receive/handling and reconnect acceptance (OpenSpec 5.4), explicit
production enrollment and sole-Mattermost cutover remain separate gates.

## Verification and rollback

[Remote five-suite acceptance](https://carverauto.buildbuddy.io/invocation/b27ab228-1cd2-424d-8b4a-ba0b8f2df7b4)
passed the packaged inbound HTTP/WS fixture, real Go checkpoint, board API,
cooperation API, existing conversations and worker runtime. Invented fixtures
cover subscribe-before-history, equal-time pages/live arrivals, edits, trusted
root/plain mention routing, echo suppression, new DM discovery, downtime,
missing/revoked sources, exact scoped handling and retained first receipts.
This is controlled protocol evidence, not production enablement or live fleet
parity. The startup regression used zero against BEAM's potentially negative
monotonic clock; the repaired owner initializes deadlines to `now()`.

Disable `AGENTBOARD_MATTERMOST_INBOUND_ENABLED` to stop the owner while keeping
metadata, pending versions and receipts. Keep schema-compatible code when
rolling back; the additive schema-18 migration has no destructive downgrade.
The working board inbox remains primary. See the retained
[architecture source](architecture/mattermost-inbound.json) and
[standalone diagram](architecture/mattermost-inbound.html).
