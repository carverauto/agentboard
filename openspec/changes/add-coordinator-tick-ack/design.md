# Design

## Baseline and authorization boundary

Inspected main `4850aecc3207744d216c32c7e177b1bc0ef8e121`, #149, #161,
`Decisions`, `Auth`, `APIAuthPolicy`, the decision-conversation contract and
current source/receipt migrations. The existing `coordinator` scope is read-only;
`coordinator_participant` adds separate explicitly granted chat operations.
Neither is promoted. The new runner scope rejects channel grants, remains
bound to the configured active, non-reserved coordinator and cannot use ordinary
agent writes. Credential default issuance remains unchanged.

All new routes require enforce mode, a presented verified bearer and protocol
revision 1. The controller/domain fail closed independently of legacy off/observe
behavior. No captain-capability fallback and no trust in actor headers. Reads
may retain existing auth last-use metadata, but never mark source content read.

## Revision-1 surface

Proposed routes under `/api/v1/coordinator`:

- `GET /tick?limit=20&max_bytes=16384&cursor=...`
- `GET /decisions/:id` for exact canonical source and current attention metadata
- `POST /ack` with protocol revision, retry key and 1–20 exact item acknowledgments
- `POST /heartbeat` with only existing bounded `status` and optional own `task`

`x-agentboard-coordinator-protocol: 1` is required. Responses identify
`protocol_revision: 1`. The CLI sends the same requests and JSON responses,
checks the explicit server capability/schema floor before requests, and never
falls back to an older mutation or captain credential.
The existing public `GET /api/v1/meta` remains the compatibility bootstrap;
it needs no runner grant and never returns protected source content. Protocol
commands must test this preflight explicitly under enforce mode.

The runner's entire allowlist is these four operations. Exact source reads can
inspect retained decisions, including terminal decisions, for reconciliation.
No broad task/inbox/chat read authority is inherited from other coordinator
scopes. Source question/findings are untrusted content and are returned only by
the explicitly requested exact read. Tick and receipt records contain bounded
metadata and server-generated relative references, not source prose, answers,
secret values or arbitrary URLs.

## Source identity and attention

Each tick item is the exact canonical decision UUID. Its version is a SHA-256
of canonical source content plus current task identity, owner and revision.
Immutable task/requester pointers and source timestamps remain visible. A
changed source or owner/task revision produces a different version, even when
the decision ID is unchanged. Do not adopt numeric IDs as commit order.

Tick includes all `status=open` canonical decisions. It does not hide a row
because a handling receipt exists. Any current-version `escalated` receipt keeps
it `captain_pending`, including after later reviewed/deferred handling. Latest
handling disposition is projected independently. A receipt for an older version cannot
suppress current attention. An owner mismatch or terminal task is shown as a
source blocker, never as permission to act on the old owner. Canonical decision
answer/withdraw/supersede removes it from subsequent open attention pages.

`policy_evaluation=not_available` discloses missing #154; no claim that every
item has been screened by a server policy engine. Native wake status is outside
this packet. Existing decision conversation and worker/wake receipts are not
coordinator handling receipts and are not altered.

## Bounds and cursors

Count and byte budgets apply to the complete encoded tick JSON envelope,
including cursor and framing. The server validates bounded scalar query input,
caps candidate reads, and selects a deterministic `(created_at,id)` ascending
prefix. `next_cursor` names the last returned source; it binds revision,
authenticated coordinator and count/byte options. Invalid, malformed or
incompatible cursors fail closed rather than restarting silently.

`complete=true` means the current query observed no additional eligible rows
after this page. It is not a stable snapshot of concurrent transactions. If a
single item cannot fit, return an explicit bounded error rather than an empty
apparently complete page or skipping that source. A late commit may sort before
the cursor, so adapters must periodically start from the beginning, and restart
after completing a traversal/reconnecting. Do not persist an end cursor as a
forever watermark. Tick alone consumes nothing and does not stamp liveness.

## Atomic acknowledgment and durable evidence

Ack requires a bounded retry key and strict items containing exact decision ID,
source version and disposition (`reviewed`, `escalated`, `deferred`). No free-form
body or recipient is accepted. Canonicalize item ordering before hashing; reject
duplicate IDs and unknown fields. Namespace the retry key to authenticated
identity and operation. Store the original batch receipt, its exact members,
first actor/model/harness and timestamp; never overwrite them.

The whole batch commits or fails. Acquire canonical `FOR NO KEY UPDATE` task locks in sorted order,
then decision locks in sorted order, then authentication identity/credential
locks and the identity/operation retry-key lock. Revalidate current credential,
registered attribution, auth mode and configured coordinator, then current
source versions/status/owner before writing. Confirm final lock ordering against
existing source/credential mutation owners. No source write, queue operation,
message, worker lock, wake or external I/O is part of acknowledgment.

An existing identical key returns its original receipt without a new mutation,
even when its source has since changed or closed. Authentication remains current:
a revoked/wrong/configuration-invalid bearer cannot fetch that receipt. A changed
body under the same key conflicts. A different key for an already handled exact
source may add new evidence without replacing the earlier record. The current
projection uses a deterministic latest receipt, with timestamp plus receipt ID
as tie-breaker. Concurrent tests must prove that equivalent retries produce one
batch, mixed stale batches produce none and source mutations cannot slip between
comparison and commit.

Coordinator configuration is currently startup application configuration rather
than a mutable role resource. Capture and revalidate that value after waiting
for locks and immediately before a new mutation. A later stable role/epoch
handoff must provide an explicit mutable configuration fence; this slice cannot
promise live seamless handover or modify stored #206 attributions.

Task locks deliberately use `NO KEY UPDATE`: they conflict with canonical
owner/source writers' `FOR UPDATE`, but remain compatible with the task foreign
key's `KEY SHARE` taken by existing participant heartbeats after their agent
lock. This avoids a task/agent lock inversion without changing old scopes or
heartbeat behavior. Credential `FOR SHARE` follows agent custody to serialize
against credential mutations. Source hashing and serialization run under
transaction-local UTC, independent of connection/database timezone defaults.

Heartbeat is a distinct explicit mutation. Validate status/task only; reject
backend, profile, model, identity, availability and arbitrary extra fields.
When a task is supplied, acquire its canonical lock before the authenticated
agent lock and recheck current ownership. Keep the original harness/model
attribution, and never renew a task lease or infer ownership from heartbeat.

## Persistence, rollout and verification

Use additive immutable batch/member resources with foreign keys, database
uniqueness and update/delete/truncate guards. Record application audit using
the normal Ash actions. Upgrade must preserve old tokens, existing decisions,
messages, worker/wake receipts and a higher aggregate schema marker. Never
allocate a migration number merely because a local checkout has a free number.

Verification covers strict API/CLI parity, serialized count/byte bounds,
non-consuming reads, invalid cursor/filter binding, late commits, historical
retries, atomic/concurrent ack, source answer/withdraw/owner races,
revocation/configuration/attribution races, old/wrong/off/observe scopes and the
absence of task/lease/wake/source-receipt effects. Use normal-role certificate-
verified TLS PostgreSQL integration and additive migration upgrade checks.
Remote Bazel remains required for publication; absent remote configuration is
reported as unrun, never replaced by local Bazel. Authorized disposable VM Go
and Mix builds provide additional evidence only.
