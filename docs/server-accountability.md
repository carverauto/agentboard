# Server accountability and delivery

This workstream owns schema 11, CI failure obligations, protected worker API,
receipts, bounded scheduling and compact PR/worker views. Collector schema 10 is
a separate dependency. Host execution and adapter conformance belong to Agent B.
The coordinated release proof remains open; this document does not assert a
production rollout or universal wake support.

## Responsibility

The collector's fenced transaction creates an immutable snapshot, current
projection, one active failure episode/repair task and one source intent. Initial
responsibility uses immutable original task submission links. Missing or
conflicting provenance goes to the captain queue. Generated repair tasks are
excluded from subsequent submission attribution. Source-task completion,
archiving, changing current task, heartbeat age and lease expiry don't transfer
responsibility. An explicit repair/source handoff records a new recipient and
suppresses old pending failure notices. The captain can resolve unknown/conflict
through protected `POST /api/v1/obligations/:id/responsibility` with `to`,
`expected_responsible_id`, `reason`, `idempotency_key`, protocol header and captain
capability. This updates assignment without claiming a task lease.

Required-check policy is explicitly configured using server-side
`AGENTBOARD_CI_POLICIES` JSON, keyed by canonical `owner/repo`:

```json
{"fixture/repo":{"tested_ref":"head","required":["check:1:Acceptance"],"accepted_conclusions":["success"]}}
```

The example is invented. Determine actual application IDs/check identities from
immutable provider evidence before configuring a repository. No default required
list is inferred from a green unrelated check. Only complete, stable current
head/base collection plus successful configured head checks verifies head-test
recovery. Merge-ref policy is unsupported and remains unknown. A verified recovery
resolves the machine episode and suppresses obsolete alerts, retaining the repair
task's existing status. A later failure starts a distinct episode.

## Delivery and recovery

See [worker API revision 1](worker-api.md) and deterministic fixture JSON.
New operations require scoped capabilities even though old board routes remain
trusted-network attribution. Captain provision is explicit; secrets are returned
once and only hashes are persisted. Revoke invalidates host/session capability
use. Replacement creates a new binding epoch and retains uncertain effects.

Canonical task/Context mutations capture a source intent in the same transaction.
Routing selects unrouted rows and missing unique source/recipient deliveries,
with a pinned audience and stored page position. UUID/sequence ordering does not
stand in for commit order. Enrollment bootstraps current owned/assigned tasks and
all unresolved obligations through paginated reads, plus 20 recent scoped Context
entries. Old Context receipts suppress pending runtime work; runtime handled
receipts and Context receipts commit together. Neither reads nor turn completion
acknowledge.

Reservation freezes at most 20 items and 10 KiB payload, with exact IDs, metadata,
source links and SHA-256 of exact UTF-8 bytes. This leaves wrapper room within the
16 KiB session frame limit. Oldest ordinary work gets a slot alongside urgent
items. Source arrival after freezing remains pending. Dispatch lease is 120
seconds and never renews the independent two-hour task lease.

An ambiguous write or expired reservation remains uncertain. Reconcile exact
receipts and current source disposition before new session I/O. Positive host
journal evidence that no adapter call started may record `not_submitted`; a
submitting-phase journal cannot. The captain may explicitly accept possible
replay effects through `POST /api/v1/workers/:worker_id/resolve_attempt` with
`attempt_id`, `decision: retry`, `reason`. This is an audited manual decision;
there is no timer-driven uncertain replay. Session capabilities cannot invoke it.

## Reminder bounds

`AGENTBOARD_COOPERATION_ENABLED` defaults false. AshOban's separate cooperation
queue schedules one-minute reconciliation. The flag also gates new reservations
and `worker.enabled`, so disabling it stops dispatch without deleting retained
batches, pending work or receipts. Every job rereads current durable
state; database locks/unique keys enforce correctness across pods independently
of queue concurrency.

After 15 minutes without meaningful repair progress, a fresh current failure may
produce one deduplicated reminder. A worker receives at most four reminder wakes
in any rolling hour across its obligations. Further unresolved state is visible
as captain escalation and one hourly digest intent. Explicit blocker and durable
pause suppress agent reminder wakes while retaining visible responsibility.
Handling an alert doesn't count as progress. A repair note/handoff postpones the
next reminder; a stale/unknown provider projection escalates without asserting a
new confirmed failure. Digests are retained source intents for captain visibility;
Mattermost delivery is a later workstream.

## Views and rollback

`/prs` is paginated; detail retains observed attempts/source links and original
submission evidence. Task/agent views keep heartbeat, task lease, connector
freshness, adapter state and notification handling separate. Capabilities come
from explicit adapter reports and are labelled declared; actual live conformance
is separate host evidence. Dashboard reads do not mutate state.

Disable cooperation and provider observation before rollout rollback. Preserve
additive tables, pending/uncertain attempts, exact receipts, obligations, task and
Context history. Do not rewind a numeric cursor, auto-reclaim tasks or clear
uncertainty. Keep merge order collector → server → worker and use no-mistakes for
PR delivery. Production activation and the controlled failed-PR/restart/recovery
proof are coordinator-owned release gates.

## Verification scope

[Remote packaged acceptance, 20 targets](https://carverauto.buildbuddy.io/invocation/95a37bdf-86ab-4ed1-83f3-3d1769cfa6df)
passes source/receipt rollback, capability fences, historical reconciliation,
late commits/interrupted fan-out, ownership/recovery/recurrence and reminder bounds.
[Server UI evidence](verification/server-ui-browser.json) records 28 actual Chrome
measurements: seven PR states at 1440/390 widths in light/dark themes. Six retained
screenshots were separately inspected, including eight connected agent/task health
width/theme checks from [the packaged full-render proof](https://carverauto.buildbuddy.io/invocation/c54bd1e1-f572-44e9-8823-355a83ff8612). The HTML is actual packaged Phoenix output
with its emitted CSS inlined and invented fixture data. These renderer fixtures
are independent of transaction recovery assertions; they are not a production
rollout or a claim that every adapter supports waking.

The disconnected agent/task render is only a loading page. Browser health evidence
must export the full actual WebSocket join render through the pinned
[Phoenix 1.1.33 diff consumer](https://github.com/phoenixframework/phoenix_live_view/blob/v1.1.33/lib/phoenix_live_view/diff.ex),
retaining the same packaged layout/CSS. This is a snapshot of a real connected
fixture session, not a mocked LiveView callback.

[Combined 24-target remote acceptance](https://carverauto.buildbuddy.io/invocation/c8f398e3-cc92-40df-b364-31ae6e5191a5)
passes on public collector `2098e250` plus this server integration. The actual
reservation callback owns atomic classified snapshot/projection/episode/task/source
commit, concurrent rejection and rollback. The actual HTTPS collector action proves
configured head-policy recovery while the repair task remains assigned. Schema 11
at migration `20261007000500` follows published collector `20261007000400` and
deployed bridge `20261007000300`; repeated schema-10 upgrade preserves immutable
snapshot, current projection, inventory, history and provider-budget bytes. The
passing constraint rejects absent JSON fields as well as unverified/merge-ref evidence.
Final native host-to-packaged-API proof and controlled live failed-PR/restart/recovery
remain explicit host/coordinator release gates. Cooperation stays default-off.

## Review cards and relative ages

Review cards with a linked PR use the same bounded domain CI projection and
180-second freshness rule as `/prs`. Text and distinct symbols identify passing,
pending, failing, unknown, stale and unavailable; color is supplemental. Cards
without a PR omit the indicator. A failed board/CI reread cannot retain a green
label. Draft requires an actual head-matched provider boolean, with missing
metadata remaining unavailable. Provider collection runs outside the UI.

The shared age formatter displays seconds below 90 seconds, whole minutes below
one hour, whole hours below one day, then whole days. Future timestamps display
“Just now”; malformed values display “Unknown age”; absent roster heartbeat
displays “No heartbeat”. The exact absolute timestamp remains visible. This
display does not change heartbeat, native-report or claim freshness, add task
status ages, or introduce another refresh timer.

The explicit [merged Review disposition](pr-merge-disposition.md) policy runs under
the observation flag: source Review tasks complete only when all recorded PR
submissions have matching immutable merged evidence. The system preserves the
assignee and records audited proof plus an owner inbox message and enabled chat
intent. CI remains separate: merge completion never turns CI green or completes
a repair task. Other source statuses and missing/unfinished links require explicit
owner/captain handling.

Packaged UI verification: `9affa783-81db-4f79-a95c-2aa90edb2e87`
proves age boundaries and Review projection labels;
`3fc62830-989e-4205-aa50-60a3f8dc2549` fails at the roster age
when only the prior raw-second renderer is restored;
`82b42d19-15fd-422b-93df-7c4818ca28ef` proves that a real
database outage replaces retained passing with unavailable. The browser receipt
retains 24 viewport/theme measurements and the separate screenshot review.

Review lookup reuses canonical GitHub inventory identity, preserving mixed-case
submission URLs. Packaged `7c5c34bb-e589-4b8b-b859-753fc94f5723` passes
with `Fixture/REPO`; restoring only verbatim URL lookup fails the intended
CI-failing badge assertion in `9b7b2e71-43a8-4f70-b27d-8af784ca6228`.

Draft freshness is tied to the current projection's exact immutable snapshot,
head and observation time. An unavailable provider leaves `Draft (last observed)`
visible beside stale CI; foreign-head metadata is omitted. Eight actual Chrome
desktop/390px light/dark measurements and separate two-image inspection passed
from the combined packaged fixture in the retained browser receipt.

The static range quality scan against public collector `2098e250..b2b33ccc` reports
eight major rows: six short cloning shapes (separate lock namespaces/digest primitives,
controller adapters and framework LiveView/HEEx callbacks), the 64-line atomic
observation orchestration and Application module growth. These preserve distinct
semantics and declarative persistence/supervision boundaries rather than introducing
shared authority or moving declarations solely to lower a metric. Macro-registered
resources/controllers/callbacks are exercised remotely despite lexical dead-code
reports. This is a recorded tradeoff; it is not a clean static quality verdict.

[Final 24-target verification](https://carverauto.buildbuddy.io/invocation/4cc5e2d5-5937-4696-b246-e9cd2726cb3a)
includes public CLI refusal while the schema marker is retained but each essential
new snapshot, receipt or obligation relation is absent, followed by successful
reads after restoration. This does not migrate or delete retained records.
