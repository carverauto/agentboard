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
or releasing another run lease. Buffer/response,
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
