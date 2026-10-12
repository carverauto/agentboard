# Worker API revision 1

Status: agreed server implementation contract; packaged acceptance evidence is
recorded separately. API namespace `/api/v1/workers`. Protocol revision is `1`,
additive database schema is `11` (collector is schema `10`). The host uses HTTPS
only. Successful state/bind records include `binding.binding_epoch` (also `epoch`),
`worker.enabled` (not revoked), and `/state.active_batch` for lost-response recovery.
Reconcile includes `resolved` for all handled/suppressed batch members.
All responses include `protocol_revision: 1`; send
`x-agentboard-worker-protocol: 1` on requests. No watch is required: poll every
30 seconds and reread after reconnect. Reads never acknowledge or renew tasks. `GET /state` can expire a reserved
attempt to retained uncertainty; it is not the non-mutating source-resolution
operation described below.

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
| `GET /continuation` | Idle continuation eligibility, suppression reasons, cooldown and limits (read-only) |
| `POST /continuation` | Explicit `no_new_finding` or outage disposition; never acknowledges a delivery |

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
Host scope can reconcile an older binding or dispatch generation using that
attempt's original epoch, generation and hash. Historical reconciliation is
read-only: it does not expire an attempt, clear a binding or acknowledge a
delivery, and always reports `replay_allowed: false`. Receipt scope remains
fenced to the current binding epoch. Retire an old host journal only with exact
handled/source-resolution or canonical `batch.status: not_submitted` proof;
validate the original frozen batch before accepting either. A missing active
batch alone is not proof. An unresolved historical submission remains blocked
for reconciliation or explicit captain action, without native I/O or result
writes. Current reconciliation permits replay only for a committed
`not_submitted` result. No idle/turn-end ack.

## Receipts

Body: `idempotency_key`, `attempt_id`, `binding_epoch`, `dispatch_generation`,
`payload_hash`, `kind` (`received` or `handled`), `delivery_ids` (1–20 exact IDs).
The IDs must belong to the frozen batch and authenticated recipient. Session
receipt capability must match the live epoch. Retrying the same key/content
retains first attribution/time; reusing a key for different content conflicts.
An exact receipt for a terminal attempt (`handled` or `not_submitted`) in an
older dispatch generation of the same epoch is retained as evidence only. It
cannot change deliveries, canonical source acknowledgements, the attempt's
committed outcome, or a newer attempt's custody. Responses include `historical`,
which classifies the attempt at response time; on a same-key retry it does not
change the original receipt or imply its original application had no effects.
Old-epoch receipt/result writes remain rejected. Exact same-epoch terminal
result retries return committed evidence without changing state.
For a current attempt, handled implies received for those IDs only. Other
members remain pending.
Context handling atomically inserts the existing Context receipt; existing CLI
Context receipts suppress runtime pending work. Notification handling never
marks a repair task done or resolves failing CI. Reconcile before acting on an
old source frame.

## Exact-attempt wake source resolution

`POST /api/v1/hosts/:host_id/wake-intents/:worker_id/resolve` is the
receiving-side, non-consuming gate for a frozen wake notice. It uses existing
host or current-epoch receipt credentials and worker protocol revision 1.
The body is exactly the five immutable fields copied from the reservation:
`attempt_id`, `intent_id`, `reason_hash`, `payload_hash`, and `recipient`.
The recipient contains the original agent, host, repository, enrollment revision,
binding epoch, session ID, and adapter generation. Do not reconstruct a new
recipient from the latest binding or substitute a newer attempt.

The response contains `actionable`, `reason_codes`, the immutable `reservation`,
and `source`. Only `actionable: true` contains canonical source material:
`kind`, `id`, `version`, `task_id`, and the current `message`, `decision`, or
`task` record. A denied currentness check returns `source: null`; malformed or
mismatched immutable references and unauthorized scopes return protocol errors.
A source-resolution read never marks a message read, acknowledges a decision,
renews or claims a task, writes a delivery receipt, expires an attempt, clears a
binding, or authorizes native replay. Retrying a lost response repeats that read.

| Exact attempt state | Resolve current source? |
| --- | --- |
| Active `reserved` | Yes, if all remaining fences pass; receipt may race result recording |
| Active `submitted` | Yes, if all remaining fences pass |
| Active `uncertain` | Yes, if all remaining fences pass; never permission to replay |
| `not_submitted`, `handled`, inactive, expired, or replaced | No |

Every allowed response rechecks current enrollment, host, binding epoch,
session/generation, active cooperation attempt, the immutable batch and source,
recipient availability and receipt capability. Pause, revocation and replacement
block actionable material. Both the wake and batch leases must still be valid.
The existing transport lease is 120 seconds: this is the receiving authorization
window for this notice, not a deadline to complete its task. `handled` records
handling of the notification, not task completion, decision application or a
native delivery guarantee. After that window, a receiver must leave the old
attempt inert and use a fresh canonical check-in to discover current work under
its separately authorized task claim and source APIs. Neither retrying the old
reference nor a previous `received` receipt renews this window. This gate adds
no automatic authorization renewal; pre-existing non-wake receipts retain their
existing lease semantics.

Task claim warnings require the exact unexpired claim; answered decisions also
require the current assignee's live claim; assignments require the latest
captain-authorized assign/handoff revision. Message sources require their exact
recipient, canonical task/repository, unread state and source version. Typed
conflict orders also use the existing current-order/default-tip custody checks.
Unsupported source kinds fail closed.

Canonical source locks precede worker custody. Mixed ordinary/typed batches
share the existing sorted task-lock tier after branch/PR/policy locks. New
current `received` and `handled` receipts for wake-backed deliveries recheck the
same currentness conditions atomically, including batches reserved through the
generic worker endpoint. An exact previously committed receipt can still be
retrieved idempotently after its source changes. Eligible same-epoch historical
terminal receipts remain evidence only and cannot mutate current deliveries;
old-epoch writes remain rejected. Explicit source handling and explicit delivery
receipts remain separate actions. Record notification handling before a separate
decision acknowledgement or task transition invalidates its canonical source;
a later new notification receipt will then fail closed. An expired active
attempt can remain unresolved for the existing explicit captain/rebind paths.

For a durable conversation adapter, the conversation identifies where an
advisory is queued; it is not a loaded runtime incarnation. A stale queued
notice can still start a turn and incur cost. This server gate prevents that
notice from obtaining actionable current source material or recording new
current handling after replacement; it cannot retract the native queue or
prevent that turn. This API adds no native profile activation or delivery proof,
and does not mint native incarnation authority.

## Idle continuation (schema 44)

Default off. `AGENTBOARD_IDLE_CONTINUATION_ENABLED=true` enables it, and it also
needs `AGENTBOARD_COOPERATION_ENABLED=true`. Enabling cooperation alone schedules
nothing. `AGENTBOARD_IDLE_CONTINUATION_DELAY_SECONDS` (60–86400, default 600)
sets the idle delay. The existing one-minute cooperation scheduler runs the sweep.
It checks at most 100 due workers per run, each in its own short transaction.

A reminder is an ordinary recipient-pinned cooperation event of kind
`idle_continuation` (priority 2, the responsibility's task and repository). It
travels the same reservation, frame and exact-receipt path as any other delivery.
Turn completion, idle state and a disposition never acknowledge it. It grants no
authority and never asks the worker to start unrelated work.

A worker is eligible only when every one of these holds:

- it is enrolled, not revoked, and not durably paused;
- its availability is `active` (captain-recorded quota exhaustion or
  out-of-service suppresses it) and it is not retired;
- it is bound, with `adapter_state: ready`, a healthy connector reported within
  90 seconds, and a last heartbeat of `idle`;
- it has no active attempt to reconcile and no `uncertain`/`not_submitted`
  attempt in the last 15 minutes (adapter failure cooldown);
- its adapter is not `blocked` on an approval and it has no open captain decision;
- it has an unresolved scoped responsibility: an `in_progress`/`review` task, an
  authorized `assigned` task, or an unresolved repair obligation with no recorded
  blocker;
- its previous reminder is handled or suppressed (at most one outstanding per binding);
- the idle delay has passed since its last observed progress or reminder, or
  since a check last found it busy.

Progress means the worker's own attributed `update`, `link`, `edit`, `handoff` or
document (`note`) task events, or a Context entry it published. Claims, renewals
and receipts are not progress. The first observation adopts existing history as
the baseline, so enrollment never triggers an immediate reminder.

After new task progress without a Context entry, the first reminder invites a
useful finding or an explicit `no_new_finding` disposition. At most one such
finding check is sent per progress, and it never requires a publication.
Following reminders only ask the worker to reconcile and continue, record a
blocker or handoff, or record a disposition. Two reminders without new progress
enter a `repeated_no_progress` cooldown of one hour, doubling per repetition up
to four hours. The worker then shows as escalated to the captain on the
existing agent and task delivery views until new progress. The server never
publishes, completes or reassigns anything for the worker.

`GET /continuation` (host or receipt capability) returns `continuation.enabled`,
`eligible`, `reason_codes`, `state` (the stored row), `no_new_finding_active`,
`cooldown_active`, `escalated` and `limits`. Reason codes include
`idle_continuation_disabled`, `paused`, `agent_unavailable`, `approval_blocked`,
`captain_decision_pending`, `agent_not_idle`, `adapter_failure_cooldown`,
`repeated_no_progress_cooldown`, `<cause>_cooldown`, `no_new_finding`,
`no_unresolved_responsibilities`, `reminder_outstanding`, `idle_delay` and the
binding health codes used by `/state`.

`POST /continuation` takes exactly `disposition`, `reason` (1–512 bytes, not
blank) and `idempotency_key` (1–128 bytes). Retrying the latest key with the same
content returns `idempotent: true`. Different content under that key is 409.

| Disposition | Effect |
| --- | --- |
| `no_new_finding` | Suppresses all continuation reminders until new progress is observed |
| `provider_outage`, `model_outage`, `quota_exhausted` | Visible `<cause>_cooldown`: 15 minutes, doubling per consecutive report, capped at four hours |

New progress clears outage and no-progress cooldowns, an active
`no_new_finding` disposition and the escalation. When the feature is disabled,
`POST` returns 409. Durable pause and revocation skip the sweep entirely.
Pending reminders stay visible and unacknowledged.

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
remain available. Agent availability also gates new reservations: an
`out_of_service` worker gets no batch with `agent_unavailable` while its
state, receipt, and reconcile reads stay available; see
[agent availability](setup/availability.md). Disabling dispatch does not manufacture receipt or repair
progress. Context capture/bootstrap excludes the publishing worker's own entries.
