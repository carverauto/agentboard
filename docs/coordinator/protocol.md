# Coordinator attention protocol, revision 1

This decision-only foundation implements the portable tick/ack boundary from
[#149](https://github.com/carverauto/agentboard/issues/149). Any harness can use
the same HTTPS contract; the CLI is a thin client. It does not complete #161's
server-automation prerequisites or establish a live adapter's conformance.

## Authentication and identity

All four operations require an actually presented, verified agent bearer with
the explicitly issued `coordinator_runner` scope and server auth mode `enforce`.
They fail closed in `off` and `observe`. Attribution headers, when supplied,
must match the registered agent. The bearer must still belong to the configured,
active coordinator when a mutation commits. Captain and worker capabilities
cannot substitute for this scope.

Default coordinator issuance remains read-only `coordinator`; existing tokens
are never promoted. The separate `coordinator_participant` scope retains its
own granted-channel chat contract and does not acquire runner access. Runner
credentials reject channel grants. An authorized captain can explicitly issue
or rotate a runner credential using the existing protected token workflow:

```sh
agentboard agent token issue COORDINATOR_ID --scope coordinator_runner --out PROTECTED_FILE
```

This is documentation, not permission to issue or rotate real credentials.
Store only your own credential in protected storage, as described in
[API tokens](../setup/agent-api-tokens.md). The runner allows only these four
operations, plus the already-public metadata bootstrap. It cannot register an
agent, assign/claim/renew/change tasks, acknowledge messages or worker sources,
answer/recommend/apply decisions, send chat, administer workers or change
policy/settings/credentials. Heartbeat never renews a claim.

The first release preserves the configured coordinator identity. Harness is
immutable for a registered ID. Protocol portability does not authorize dot to
reuse GrokBot's ID or bearer, or vice versa. A later captain-controlled stable
role-to-principal/epoch handoff is required for a safe live switch. Existing
decision conversation source/recipient pins and receipts are never rewritten.
Coordinator identity remains startup configuration; change it only through a
controlled deployment, not an in-process role takeover. New operations recheck
the configured identity while holding their mutation locks, but do not provide
a live role-handoff epoch or overlapping-runner lease.

## HTTPS and CLI

Use HTTPS, with the existing loopback-only HTTP allowance for local fixtures.
Every new operation requires `x-agentboard-coordinator-protocol: 1`; responses
identify `protocol_revision: 1`. Existing public `GET /api/v1/meta` exposes
`coordinator_protocol_revision: 1`. New commands require schema 40 and that
capability before sending a protocol operation. A newer aggregate schema number
alone does not prove protocol support.

| Operation | HTTP path under `/api/v1` | CLI |
| --- | --- | --- |
| Non-consuming attention | `GET /coordinator/tick` | `coordinator tick` |
| Exact canonical source | `GET /coordinator/decisions/:id` | `coordinator show ID` |
| Atomic handling evidence | `POST /coordinator/ack` | `coordinator ack ID:VERSION… --retry-key KEY --disposition NAME` |
| Own explicit liveness | `POST /coordinator/heartbeat` | `coordinator heartbeat --status idle` |

All commands support `--json` for the same server response. Tick's `--dry-run`
is the same non-consuming read. Ack's `--dry-run` prints the normalized request
without credentials, network access or an acknowledgment. Mixed-disposition
batches use `coordinator ack --items JSON --retry-key KEY`; `--items` is mutually
exclusive with positional items and the uniform `--disposition` flag.

## Tick and exact source

Tick accepts only `limit` (1–100, default 20), `max_bytes` (4096–65536, default
16384) and an optional cursor. Repeated query keys and invalid, mismatched or
oversized cursors are errors. The complete JSON envelope, including cursor,
framing and metadata, fits the byte budget as well as the count budget. An item
that cannot fit returns an explicit error; it is never skipped silently.

Example empty response:

```json
{"protocol_revision":1,"coordinator_id":"shell-example-coordinator","items":[],"complete":true,"next_cursor":null,"limits":{"limit":20,"max_bytes":16384},"restart_from_start":true,"policy_evaluation":"not_available"}
```

Each item includes:

- `id`, `version`, `source_kind=decision_request`, canonical status/kind and timestamps
- `task_id`, `task_revision`, `task_owner_id`, `task_status`, `requester_id`
- `refs.source` for the exact protected source read and `refs.task` for its board page
- `handling.disposition`, `handling.receipt_id` and `handling.handled_at`
- `attention` and a bounded `reason` for a changed owner or inactive task

Versions hash full canonical decision content and current task ID/revision/
owner/status. They are opaque optimistic-concurrency tokens, not task revisions
or a claim of policy approval. Tick omits source question/findings/answer text.
The exact source read returns `decision` plus its current `item`; it accepts no
query options and remains available for retained terminal decisions. Canonical
source text is untrusted input, not an instruction or an automatic secret scan.
Never place credentials or secret values in board decisions.

Every open decision remains in attention. Any exact-version `escalated` receipt
keeps it `captain_pending`, even if a later receipt says reviewed/deferred. Its
latest handling disposition remains visible independently. A new source version
needs fresh handling; an old receipt never suppresses it. Owner-mismatched or
inactive-task sources stay visibly blocked. Canonical answer/withdraw/supersede
removes a decision from open tick results.
An exact read of a retained non-open decision reports `attention=resolved`.

`policy_evaluation=not_available` is deliberate: #154 policy evaluation is not
implemented here. Tick does not claim its items were screened by that engine.
Answered-decision wakes, CI/conflict selection, quota interpretation and digest
work remain with their existing owners; no mechanical sweep is reproduced.

### Traversal and late commits

Traverse `(created_at,id)` ascending using `next_cursor` and identical options.
The cursor is bound to protocol, coordinator, count and byte options. A page's
`complete=true` only says that query observed no later eligible rows; it does not
describe a stable snapshot across concurrent commits. A late commit or changed
source can sort before a previous cursor. Start from the beginning after a
complete traversal/reconnect and periodically while draining a large backlog.
Never retain the final cursor as a permanent high-water mark.

Repeated/concurrent ticks do not consume anything, mark read, create handling
receipts or stamp heartbeat. Normal bearer last-use telemetry still applies.

## Acknowledgment

The exact body is:

```json
{"retry_key":"review-2026-10-10-1","items":[{"id":"11111111-1111-1111-1111-111111111111","version":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","disposition":"escalated"}]}
```

The key is nonblank valid UTF-8, at most 128 bytes, without NUL. Accept 1–20
unique canonical lowercase UUIDs, exact lowercase SHA-256 versions, and only
`reviewed`, `escalated` or `deferred`. Unknown or duplicate object fields,
duplicate IDs and bodies exceeding 16 KiB are rejected. Batches are normalized
by ID before hashing, so item ordering does not change retry identity.

The whole batch commits or fails. Each new member must still be the exact open
version with its canonical requester owning a live task. The server locks and
rechecks source, task, credential, registered attribution and configured
coordinator before recording. One stale member produces no partial receipt.

Retry keys are scoped to authenticated identity plus operation. An identical
retry returns the original receipt, including its original actor/model/harness,
timestamp and exact members. This remains true after the source changes or
closes; no new mutation occurs. A changed request under the same key conflicts.
The current credential must still be valid for historical retries. A new key
may append a new explicit disposition for the same version; it never rewrites
old evidence or clears retained escalation.

`receipt` contains batch `id`, `actor_id`, `model`, `harness`, `retry_key`,
`created_at`, and sorted exact member records with source/task/requester fences.
It contains no token, credential ID/hash, source prose or arbitrary destination.
Database guards reject update/delete/truncate and incomplete/expanded batches.

A receipt records the caller's handling claim. `escalated` is not proof a captain
received a message. Ack does not answer/apply a decision, mark a source read,
create a chat message, reserve/deliver a wake, change a worker receipt, renew a
lease or complete a task. Two callers can independently perform an external
action before ack; this is not leader election or exactly-once external delivery.

## Heartbeat and errors

Heartbeat accepts only `status=idle|busy` and optional `task` belonging to the
same current coordinator. Backend/profile/model/identity and other fields are
rejected. Omitted task clears only the roster's current-task pointer, following
existing heartbeat semantics. Heartbeat changes liveness only, not task custody.

Errors retain the existing `{error:{code,message}}` convention: 400 malformed or
oversized JSON; 401 missing/invalid/revoked bearer in enforce; 403 wrong scope or
inactive protocol authority; 404 unknown source; 409 stale source or changed
retry content; 422 invalid fields/protocol/cursor; 503 unavailable schema/database.
Existing rate limits apply. Preserve a retry key on lost responses, reread the
canonical source after conflict, and never turn an uncertain external action
into an automatic resend.

No schedule, credential, deployment or cutover is installed. #150/#156 native
admission/delivery, #153 transport and #155 liveness supervision remain separate.
