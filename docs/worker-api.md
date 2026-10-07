# Worker API revision 1

Status: agreed server implementation contract; packaged acceptance evidence is
recorded separately. API namespace `/api/v1/workers`. Protocol revision is `1`,
additive database schema is `11` (collector is schema `10`). The host uses HTTPS
only. Successful state/bind records include `binding.binding_epoch` (also `epoch`),
`worker.enabled` (not revoked), and `/state.active_batch` for lost-response recovery.
Reconcile includes `resolved` for all handled/suppressed batch members.
All responses include `protocol_revision: 1`; send
`x-agentboard-worker-protocol: 1` on requests. No watch is required: poll every
30 seconds and reread after reconnect. Reads never acknowledge or renew tasks.

## Credentials and scope

Captain uses the existing protected `x-agentboard-captain-token` capability.
`POST /api/v1/workers/provision` accepts `worker_id`, `host_id`, `repos` (canonical
`owner/repo` strings), `model`, `harness`, `idempotency_key`. It enrolls the existing
registered agent and returns a host token once. A retry returns the enrolled
record, not a secret. Captain can revoke with
`POST /api/v1/workers/:worker_id/revoke`. Rotation requires a new provisioning
key. Secrets are random 256-bit capabilities, persisted only as SHA-256 hashes.
Clients store returned secrets in protected storage and never log responses.

Every other route requires `Authorization: Bearer <capability>`. Host tokens
authorize only their worker, host and provisioned repositories. Bind returns a
separate session receipt token once, restricted to that binding epoch and exact
receipts/read state. Legacy identity headers are attribution, not authentication.
Bind/pause/resume/unbind and reservation require host scope. Receipt scope cannot
reserve, change scope, choose recipients or rebind. Revocation disables both.

## Routes

| Method/path after `/api/v1/workers/:worker_id` | Operation |
| --- | --- |
| `GET /state` | Enrollment, binding, desired pause, health and active attempt |
| `GET /pending?cursor=UUID&limit=20` | Non-consuming deliveries, ascending UUID keyset, max 100 |
| `GET /responsibilities?cursor=TASK&limit=20` | All scoped assigned/owned tasks, including terminal sources |
| `GET /obligations?cursor=UUID&limit=20` | All unresolved scoped PR obligations |
| `POST /bind` | Verified explicit identity/capabilities and incremented epoch |
| `POST /state` | Connector health/capability report, epoch fenced |
| `POST /reserve` | Freeze batch and attempt before external I/O |
| `POST /attempts/:attempt_id/result` | `submitted`, `not_submitted`, or `uncertain` |
| `POST /attempts/:attempt_id/reconcile` | Read/reconcile current source and exact receipts; never automatic replay |
| `POST /receipts` | Exact `received` or `handled` delivery IDs |
| `POST /pause`, `POST /resume`, `POST /unbind` | Durable desired state, epoch fenced |
| `GET /doctor` | Protocol/scope, connector, binding/adapter and receipt-path health |

Bind body: `idempotency_key`, `expected_epoch` (0 initially), `host_id`,
`session_id`, `pane_id` (opaque handle), `adapter`, `adapter_version`,
`capabilities`. Each capability `idle_wake`, `turn_start`, `tool_return`,
`receipt`, `recovery` is `{supported: boolean, reason: string}`. Unsupported
capability must provide a reason. Bind never infers identity from model/title.
Replacement requires an explicit new bind. Rebinding preserves pending deliveries
and parks any old unresolved external attempt as uncertain.

State/pause/resume/unbind bodies require `binding_epoch`; state accepts bounded
`connector_state`, `adapter_state`, `reason`, `capabilities`. Host health never
changes agent heartbeat, task claims or responsibility. Doctor's receipt path
means the protected API is available; actual adapter conformance remains host
evidence and is never inferred from a declaration.

## Reservation and payload

Reserve body: `idempotency_key`, `binding_epoch`. Empty/paused returns
`batch: null` with `degraded_reasons`. Otherwise returns `batch` containing
`batch_id`, `attempt_id`, `worker_id`, `binding_epoch`, `dispatch_generation`,
`payload_hash` (lowercase SHA-256 of exact UTF-8 `payload`), `payload`,
`delivery_ids`, `lease_expires_at`, `continuation_url`, `more`.

Default dispatch lease: 120 seconds, independent of two-hour task lease.
At most 20 deliveries and 10,240 UTF-8 payload bytes (leaving host wrapper room within 16,384 bytes) including framing/metadata. Source
summaries are bounded; every item includes exact IDs, source and fetch links.
Ordinary oldest work receives at least one slot when urgent work exists. Arrivals
after freezing stay pending. The stored payload is immutable. Persist exact
batch/attempt/epoch/generation/hash and journal phases **before session I/O**.

Result body: `binding_epoch`, `dispatch_generation`, `payload_hash`,
`status`, bounded `reason`. `not_submitted` requires positive adapter evidence
that no write occurred. Timeout/crash/lease expiry is `uncertain`. A reservation
whose lease expired becomes uncertain and remains the active attempt; it never
automatically becomes eligible for replay. Submitted also remains active until
exact handling receipts. Epoch/generation/hash mismatches return conflict.
Reconcile body has the same fences; response includes frozen batch, current
delivery dispositions, exact receipts, `resolved`, and `historical`.
Host scope can reconcile an older binding using that attempt's original epoch,
generation and hash. Historical reconciliation is read-only: it does not expire
an attempt, clear a binding, acknowledge a delivery or permit an old receipt or
result write. Receipt scope remains fenced to the current binding. Retire an old
host journal only with exact handled/source-resolution or explicit non-submission
proof; a missing active batch alone is not proof. An unresolved historical
submission remains blocked for reconciliation or explicit captain action.
Reconciliation reports `replay_allowed: false` unless a
committed `not_submitted` result permits a new reservation. No idle/turn-end ack.

## Receipts

Body: `idempotency_key`, `attempt_id`, `binding_epoch`, `dispatch_generation`,
`payload_hash`, `kind` (`received` or `handled`), `delivery_ids` (1–20 exact IDs).
The IDs must belong to the frozen batch and authenticated recipient. Session
receipt capability must match the live epoch. Retrying the same key/content
retains first attribution/time; reusing a key for different content conflicts.
Handled implies received for those IDs only. Other members remain pending.
Context handling atomically inserts the existing Context receipt; existing CLI
Context receipts suppress runtime pending work. Notification handling never
marks a repair task done or resolves failing CI. Reconcile before acting on an
old source frame.

## Bootstrap, recovery and errors

Provisioning starts at enrollment time for new workspace events. Bootstrap
includes **all** authorized current responsibilities and unresolved obligations,
with pagination, plus up to 20 recent unhandled scoped Context entries. Older
Context is available via existing search/detail APIs and isn't new work by
default. Router selects durable unrouted intents and missing recipient rows;
sequence values aren't a commit-order cursor. Lost notifications need no special
recovery API. Check-in traverses all responsibilities/obligation pages and pending
pages. Source-task done/archive never deletes responsibility.

Errors use `{error: {code, message}}`: 401 `unauthorized`, 403 `forbidden`,
404 `not_found`, 409 `conflict`, 422 `invalid_input`/`invalid_context`,
503 `unavailable`/`schema_unavailable`. Missing/wrong protocol is 422
`protocol_mismatch`. Existing rate limiter returns 429 with `Retry-After`.
Respect cancellation; jitter reconnect 1–60 seconds, honor longer Retry-After.
Do not replay an uncertain write: reread state first. Messages exclude secrets.

## Executable request pattern

Use protected curl configuration (0600) containing an authorization header;
do not put tokens in command arguments. Example with invented fixture identity:

```sh
curl --config "$WORKER_CURL_CONFIG" \
  -H 'x-agentboard-worker-protocol: 1' \
  https://agentboard.example/api/v1/workers/fixture-agent/pending
curl --config "$WORKER_CURL_CONFIG" \
  -H 'x-agentboard-worker-protocol: 1' -H 'Content-Type: application/json' \
  --data-binary @docs/fixtures/worker-reserve-request.json \
  https://agentboard.example/api/v1/workers/fixture-agent/reserve
```

Deterministic wire examples live in `docs/fixtures/worker-*.json`. They are
invented, contain no credentials and are contracts for transport development,
not proof of packaged API or live adapter integration.

Credential rotation requires prior revocation and retains the same registered worker, host and repository scopes. Use a new worker identity for different scopes. The binding includes `reported_at` for native health freshness; dispatch updates do not refresh it.

`worker.enabled` also reflects the global `AGENTBOARD_COOPERATION_ENABLED`
switch, which defaults false. While disabled, reservation returns no batch and
reports `cooperation_disabled`; retained batches, pending rows and reconciliation
remain available. Disabling dispatch does not manufacture receipt or repair
progress. Context capture/bootstrap excludes the publishing worker's own entries.
