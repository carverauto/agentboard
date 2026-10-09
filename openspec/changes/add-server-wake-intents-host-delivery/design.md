# Design

## Context

See proposal.md for motivation. Discovery is pinned to main `db381fccfc32080ea9ba07b223caaf8aea5ed400`; these are observed boundaries, not new readiness claims:

| Existing owner | Evidence | Design consequence |
| --- | --- | --- |
| Decision answer capture | `web/lib/agentboard/decisions.ex`, capture_wake | Reuse its stable decision source and frozen audience; do not create a second answer wake. |
| Scoped cooperation dispatch | `web/lib/agentboard/cooperation/runtime.ex`, reserve | Existing 120-second batch lease, binding epoch, immutable payload and received/handled receipts remain authoritative. |
| Host uncertainty journal | `internal/worker/runtime.go`, Step / submitAttempt | Reuse one local lock and journal before native I/O; transport success is not handling. |
| Native adapters | `internal/worker/adapter.go` | Pi/Claude versions are accepted; Herdr/manual currently refuse automatic dispatch. No blanket parity. |
| Seat recovery | `internal/cli/seat_attach.go` and #164 restart-boundary contract | Use existing lease/WIP and exact physical cwd checks; missing custody refuses restart. |
| Availability | `web/lib/agentboard/availability.ex` | Use DB-clock effective availability and existing policy locking; never treat Herdr state as board ownership. |
| Host install preview | `internal/worker/install.go` | Keep install ownership manifests and activation separate. |

The main spec inventory is empty. Preserve the in-flight runtime's exact receipts/uncertainty/safe-boundary requirements. `seat nudge`, `host schedule install`, `host run` and a wake-intent HTTP namespace are proposed interfaces; they are not present in this checkout. The #150 owner was asked to agree the shared boundary before implementation. #123's structured task dependencies are not present: a free-text blocked note is not a machine-authoritative dependency.

Bundled installed Herdr API schema inspection exposes pane send-text/input/keys parameters without composer occupancy or expected-recipient revision fields. This static inspection does not prove live-server capabilities or race-free submission; negotiate the installed profile and test a disposable native session. Never emulate a guarded submit with two snapshots around unguarded send keys.

## Goals / Non-Goals

**Goals:** deterministic server reason occurrences; one eligible native submission owner; exact host/generation fencing; durable uncertainty and truthful dry-run/readiness.

**Non-Goals:** fleet/loadout/Deck reconciliation, a new chat corpus, generic shell execution, implicit task pickup, automated decision application, roster mutation, production service/hook activation, or claiming #164 runtime complete. Other harness slices remain under #52.

## Decisions

### 1. Intent is a source reference, not a new responsibility

Use proposed audited WakeIntent and WakeAttempt records, with intent revision and unique `(recipient, reason, subject_key, source_version)` / reason_hash. Store source kind/id/version, repository, canonical task reference, eligibility/due time, availability snapshot, and opaque existing delivery references. Do not store tokens, arbitrary paths, native argv, or full Mattermost message copies. Candidate payload text is bounded source data, never authority. The same hash always resolves to the same intent.

Capture transactionally where canonical mutation owners permit it. Reconciliation uses pending-state queries and unique inserts, not a monotonic maximum-ID cursor; late commits remain discoverable. External Mattermost observations use the existing worker's authenticated inbox/version ledger; no parallel subscriber. If a producer cannot supply authoritative facts, expose unsupported, not an inferred wake.

| Reason | Subject / source version | Terminal or invalidation condition |
| --- | --- | --- |
| unread_dm | canonical message ID; or Mattermost post ID plus exact edit/version identity | exact source read/deleted/own-send/echo suppressed; only worker handling marks handled |
| decision_answered | existing decision wake key plus answered revision | original answer applied/acked, cancelled/superseded or canonical gate mismatch |
| claim_expiring | task ID + rightful owner + exact claim expiry | renewal changes expiry, claim terminal/foreign, or original warning occurrence handled |
| idle_assigned | authorized assigned task + assignment revision | assignment changes, task becomes in_progress/terminal, availability changes |
| blocker_shipped | dependent task + explicit blocker link + terminal event | link removed or superseded; other open blockers remain visible |

Proposed defaults for captain approval: reconcile every 30 seconds with bounded pages; claim warning at 15 minutes remaining; max 32 source refs and 16 KiB rendered prompt per batch; ordinary native nudges no more than once per agent per 5 minutes. New urgent answers/DMs retain priority but use the same eligibility gate. A clock tick/cooldown expiry never creates a new reason hash or authorizes replay of the same accepted intent. These are not approved recovery defaults.

### 2. Keep a single dispatch and acknowledgement ledger

Link intents to existing cooperation source/recipient deliveries. A decision already captured in DecisionWake is adopted/referenced by its stable key; no duplicate inbox/worker wake. Non-enrolled recipients retain durable inbox fallback without automatic prompting. Enabling a host later adopts pending source identity rather than recreating already handled items.

An authenticated host poll returns eligible references, never consumes them. Proposed scoped routes under `/api/v1/hosts/:host_id/wake-intents` expose bounded list, reserve, result and reconcile operations. Use a per-worker host credential file from the existing enrollment substrate; a single daemon may own multiple independently scoped bindings. A caller cannot enumerate or reserve another agent/repository by choosing URL fields or attribution headers.

Reservation takes availability admission, then canonical task/decision locks where relevant, then worker/binding and intent/attempt locks in a documented total order. Do not call the current worker-lock-first dispatcher while already planning to acquire task/decision locks in the opposite order. One reservation CAS freezes source refs/hash, host/enrollment revision, binding epoch, native session/generation, expiry and attempt UUID. A repeated key returns the same result; competing daemons cannot reserve competing native effects for that incarnation.

### 3. Compose the daemon around existing worker ownership

`agentboard host run --config PATH` is the proposed long-running CLI; config is a protected local file with allowed host identity, worker bindings, owned transport handles, repository scopes and token-file references. Never accept shell text/native argv/credential values from the server. Pull with jitter and bounded backoff; network interruption leaves durable state pending. Webhooks may accelerate discovery later but are not a correctness dependency. Do not create a detached harness watcher or a second implementation of `worker.Step`.

A local file lock serializes daemon, foreground check-in and #150 nudge invocations. Compose #150's inspection/admission contract; if unavailable, report the dependency and keep dry-run only. Host journal phases are reserved, submitting, result, reconciled. Persist submitting before native I/O. A lost result stays uncertain; lease expiry, timeout, idle or host restart cannot prove non-submission. Native correlation/receipts, or explicit proof that no call began, settle it. Unknown effects remain visible and block a second submit.

### 4. Prove Herdr first, advertise only what is proved

A bound profile needs installed API version/schema, exact server/workspace/pane/native session/generation identity, supported boundary semantics, and reconciliation evidence. The delivery operation must atomically reject changed recipient, working/blocked/unknown state, occupied composer or approval UI. A local observed idle flag alone is insufficient. If installed Herdr lacks that contract, the adapter remains unsupported with manual check-in available; validate a supported native profile only as a separately attributed fallback.

Publish readiness independently for each host/binding and each action (inspect, idle_wake, native receipt, reconcile, restart). Health and model heartbeat remain separate. Each source frame directs canonical check-in and preserves original tool results. It does not renew leases, acknowledge messages, apply decisions, or resolve CI.

### 5. Keep restart a separate effect class

The #164 `seat.restart` extension carries episode/attempt identity, expected enrollment revision, old binding epoch/session, approved policy/version and an opaque locally registered seat reference. Host validation resolves that reference locally, verifies preserved expected lease/WIP/No-mistakes custody and generates/checks the mandatory STOP brief through #141. Missing custody never falls through to general seat ensure allocation.

Ordinary nudge admission cannot restart a busy or absent session. Restart requires a separately proven capability and active policy supplied by #154/#164; those integrations remain disabled now. Results distinguish still_alive, known_absent, refused, uncertain and restarted. Uncertain is nonterminal and cannot cause a second spawn. Restarted requires new binding/session proof; the host transports proof but does not make the #164 machine operational or authorize answer replay. Exhaustion/escalation is owned by #164/#155.

### 6. Default to dry-run; cut over explicitly

Default host mode is dry_run. It computes candidate/eligibility explanations without reserving, submitting, reading-as-handling, modifying claims or renewing leases. #150 parity compares exact reason hashes/source refs with the existing nudger in shadow mode. A captain-approved per-host/agent cutover elects one wake owner; stop the old nudger only after native acceptance, reconnect and uncertain-outcome proof. Rollback pauses new dispatch and restores the old owner explicitly, while preserving pending/uncertain journals. Installation only previews or writes owned files, never bootstraps launchd/systemd or activates secrets/hooks.

## Risks / Trade-offs

- Missing Herdr atomic safe-input support → report unsupported; ship durable intents/dry-run without claiming automatic delivery ready.
- Two wake owners or legacy fallback bootstrap → stable source adoption, one local lock and one elected owner, exact replay tests.
- #123 terminal event confused with deploy success → preserve event/merge/deployment evidence separately; do not auto-resume or infer free-text dependencies.
- Enrollment/pause/availability races → server reservation fence and host pre-I/O revalidation; uncertain calls remain preserved.
- Schema collision → reserve a new version before implementation and prove collision-free fresh DB migrations; do not reuse #164's 31.
- Current main's duplicate roster/recovery migration → separate Muse-owned P0 repair; not changed by this proposal.

## Migration Plan

1. After proposal approval, reserve schema and confirm #150 / #123 contracts. Add additive audited resources and auth-scoped API with default dry-run.
2. Reuse existing source/receipt IDs; backfill only unresolved occurrences with deterministic identity. Keep old APIs and inbox fallback readable.
3. Prove packaged HTTP/Postgres and disposable native-host behavior remotely. Report unsupported bindings explicitly.
4. Publish one reviewed PR at a time through native No-mistakes without --yes, preserve fixes, record exact-head CI and docs; never merge.
5. Separate captain activation approves enrollment/credential provisioning, owned service loading and wake-owner cutover. Implementation approval alone does not activate production.

## Interface Agreement Checkpoint

#150 owner reply1536 agrees the proposed server/host boundary as a design recommendation, not a landed contract or captain approval. Its original local reason-hash scope must converge with server canonical hashing before cutover. The proposed typed envelope/admission/receipt seam is in contracts/README.md and wake-reservation.schema.json; implementation still requires a durable exact owner agreement. #169 consumes this channel rather than adding another wake loop. #123 owns blocker links/terminal events and keeps legacy notes manual. #164 supplies restart policy/episode fences only after its real policy/escalation integrations exist. These missing dependencies produce explicit readiness reasons, not a wider implementation scope.

### Confirmed owner receipts after approval

Board owner messages1607/1611/1622 establish that #150's shared host admission,
safe-input, journal and schedule interface is still proposed; readiness is
`nudge_admission_unavailable (#150)`. #123 has no explicit blocker-link/terminal
event producer; readiness is `dependency_events_unavailable (#123)`. This
confirms ownership and absence, not a deployed producer or native capability.

#169 owner messages1662/1669 correct `pull_request_id` to the canonical SHA256
64-hex ID. Contract v1 is durable board document176, `/documents/176/download`
under the configured board URL, SHA256
`79b17c4ca84aa4931a242c0ec67c73323e357ecaf2e5995a40478a6d912deb33`, embedded
machine schema `conflict-order-ref-schema`. Consumer acknowledgement1674 follows
an exact download/hash/schema check. The event key is
`conflict-order:<order UUID>:<positive revision>`; occurrence identity remains
the single canonical Message.id/created_at, with no new conflict-wake enum.

The #122 sole delivery selector and #169 current-order resolver remain pending.
Typed capture is additive to the existing repo-string capture call. A typed
producer suppresses generic notice capture in its sole source transaction, then
passes `{"repo": "owner/repo", "order_ref": <v1>}`. Different typed metadata
cannot overwrite an already captured occurrence. Missing current-order,
supersession/default-tip/evaluation-base and native custody proof means
unsupported/manual; neither prose nor a typed envelope establishes currentness.

The #169 prefix is BaseWatch → canonical PullRequest → PollState, then
availability admission → stable candidate-agent rows → repair task → current
order/source election → immutable message → worker/subscription/binding →
intent/attempt. Never acquire a base/PR lock below admission or worker custody.
Ordinary #156 capture/reservation acquires availability and canonical
task/request/wake/message before election and worker custody, and does not call
the missing #169 resolver. Routing completes its event/recipient transaction
before a request locks its selected worker. Provider/native I/O stays outside
all database locks. The existing #169 bootstrap must be lifted before its future
producer is enabled; this checkpoint does not claim its shared concurrency proof.

### Implemented shadow and server preparation boundary

Schema33 stores one audited occurrence and one audited attempt linked to the
existing cooperation attempt. Host-scoped routes use existing per-worker host
credentials, protocol1 and exact host/worker/repository fences. Enrollment
revision is the existing `enrolled_at` UTC timestamp in microseconds, stored as
bigint; rotation changes it without a parallel enrollment counter. A reservation
hash binds intent revision, reason hash, host/enrollment/session/epoch/pane,
cooperation attempt and its immutable batch hash, source version and delivery ID.
Its separate cooperation fences are retained internally for exact receipt reuse.

The server preparation gate `wake_delivery_enabled` defaults false. The host
daemon is shadow-only and rejects `--dry-run=false`; it cannot use this flag to
gain native authority. One source is reserved per CAS, using the existing
stricter 20-delivery/10KiB cooperation frame ceiling within the approved
32-reference/16KiB outer bound. Reads remain non-consuming and always refuse
native dispatch. Source discovery uses bounded pending-state queries every30s
via one unique Oban job per live enrollment; the existing minute scheduler
repairs missing jobs in pages of20. Neither job dispatches, acknowledges, renews
claims or sends model heartbeats.

### Current #122 return-shape gap

Owner msg1696 reports Runtime.fallback/4 returns an existing Event for worker election and a Message for inbox election; document176 proposed a sole canonical Message. Those shapes are not yet reconciled. The typed capture API validates canonical Message plus order_ref only; it cannot fabricate another Message/frame from a worker Event. The #169 producer/currentness path remains unsupported/manual until the sole-source return contract and resolver are supplied. Canonical DM/decision capture and server/host shadow do not depend on inventing this bridge.
