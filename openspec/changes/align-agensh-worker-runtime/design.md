# Design

## Context

See `proposal.md` for motivation. This is a proposed architecture, not evidence that adapters, a bridge, or CI observation are deployed.

Inspected baseline: fresh `origin/main`, `05e11f63a528b35415f7bbe293735b6af5f00f56` (2026-10-06). There are no archived main specs yet; completed and active change deltas remain relevant contracts.

| Evidence | Observed behavior / implication |
| --- | --- |
| `web/lib/agentboard/application.ex`, `delivery/discovery.ex` | Repo pool, PubSub, notification connection, AshOban housekeeping and optional inventory catch-up. Catch-up is not CI monitoring or a worker router. |
| `web/lib/agentboard/context.ex`, `context/receipt.ex` | Typed publication, BM25, recent reads, per-agent explicit entry receipts. Unacknowledged reads use receipt absence, avoiding a numeric high-water loss on late commits. |
| `web/lib/agentboard/board/operations.ex` | Handoff currently commits assignment, timeline and board message together. It must stay atomic during transport migration. |
| `web/lib/agentboard_web/live/board_live.ex` | Task detail loads a board thread/documents/history, but not actual Shared context. |
| `docs/participation.md`, `skills/agentboard-herdr/SKILL.md` | Skills do not install wake mechanisms; Herdr is currently metadata only. |
| `docs/setup/mattermost.md`, `k8s/components/mattermost/` | Chat deployment exists; bridge/identity/delivery are still planned. Sharing CNPG does not make either application's tables a public integration API. |
| `openspec/changes/adopt-ash-and-monitor-pr-ci/tasks.md` | 9/37 complete. Provider observations, current-head CI truth, follow-ups and completion guards remain separate unfinished work. |
| Firstmate `docs/supervision-protocols/{codex,claude,grok,pi}.md` | Durable wake/explicit acknowledgement with different continuation mechanisms; Pi owns session generations, Claude owns Stop rewake, Grok uses native completion, Codex uses bounded foreground checkpoints. Evidence is local Firstmate behavior, not proof our agents already have these integrations. |

Primary references: [Agensh §2 / Appendix B](https://arxiv.org/html/2609.26781v1), [project](https://agens-harness.github.io/project/), [Herdr socket API](https://herdr.dev/docs/socket-api/), [agent automation](https://herdr.dev/docs/agent-automation/), [Mattermost bots](https://docs.mattermost.com/developers/integrate/reference/bot-accounts). The paper describes per-worker queues, persistent-session dispatch, reconnect recovery and tool-return delivery. Our implementation below adapts that mechanism to existing board ownership and heterogeneous user-owned sessions; it does not reproduce the paper's benchmark permission to choose arbitrary work or merge autonomously. Its linked Microsoft source repository was unavailable when checked; no implementation claims depend on reading it.

## Goals / Non-Goals

**Goals:** A worker can lose conversation context, restart, or miss notifications and still recover its authorized responsibilities, relevant findings and peer messages. Humans can identify the responsible agent, see why delivery is stalled, and distinguish notification handling from completed repair. Keep every worker's cooperation protocol equivalent while adapters handle transport differences.

**First release:** A submitted PR fails after its agent moves on; the server detects it, the responsible agent receives a durable repair alert, and a visible obligation persists until repair or explicit disposition. Mattermost migration, whole-fleet enrollment and universal Context injection are subsequent releases, not prerequisites. A dashboard row or a skill reminder alone does not satisfy this release.

**Non-Goals:** A central planning agent; automatic issue assignment/lease takeover/merge; a second chat UI or searchable copy of Mattermost; Herdr-driven roster GC (#42); Herdr title projection (#25); arbitrary shell interruption; universal hook support without proof; replacing a user's harness or transcript; NATS/Dgraph additions; general board authentication retrofitting; copying Firstmate's captain/away-mode supervision brain.

## Decisions

### D1. Three planes, one cooperation protocol

| Plane | Authoritative state | Worker use |
| --- | --- | --- |
| Workspace | GitHub code/branches/PRs; board tasks, explicit leases, events, PR links, immutable HTML artifacts | Gather state, claim authorized work, record progress, verify delivery |
| Conversation | Mattermost channel posts, task threads, worker DMs | Coordinate interfaces, collisions, reviews and handoffs |
| Findings | Existing Context entries/links/receipts, PostgreSQL BM25 | Reuse evidence and failures; publish attributed findings and patch summaries |

Delivery envelopes are transport bookkeeping referencing those planes, not a fourth knowledge/chat store. BM25 indexes only `context_entries`. HTML documents remain in PostgreSQL and served through the sandbox viewer. Context `CLAIM` describes intention; only a task claim grants board ownership. An automatic context observation never turns untrusted text into instructions.

The common protocol is: reconcile goals/ownership/pending obligations and recent relevant findings; announce intention; act within the authorized scope; verify and repair submitted PRs; publish useful evidence; explicitly handle delivery items; repeat only while authorized work remains. Resuming runs this protocol regardless of conversation memory. Idle reminders do not invent work. Skills explain it; runtime integration makes pending work reappear.

Alternative: route all state through chat or a captain model. Rejected because it loses the durable task/context distinction and introduces the same memory dependency this work is meant to eliminate.

### D2. Server ledger and host service, with separate failure domains

The Phoenix app adds an Ash `Cooperation` domain for resources/actions; AshPostgres stores durable state, AshPaperTrail versions meaningful configuration/binding changes, AshEvents records delivery transitions, and AshOban runs bounded reconciliation, routing, retry and bridge jobs. Do not duplicate every heartbeat/body into audit tables.

`agentboard worker serve` is a proposed Go subcommand running on each worker host, supervised by launchd on macOS and systemd on Linux. One service can multiplex several independent worker bindings, each with its own cancellation, dispatch mutex, reconnect state and retry budget. The executable is installed in `~/.local/bin` using remote-built release assets. The host reaches Agentboard only over HTTPS; it has neither PostgreSQL credentials nor a database connection.

The host service supports a registered adapter interface: inspect binding/capabilities, prepare/submit a bounded delivery frame, reconcile an uncertain attempt, receive explicit consumption/handling receipts, and observe lifecycle. The runtime does not instantiate a central model. A slow worker or Mattermost outage cannot block unrelated agents or task/context writes.

Use ordinary domain functions in request/job processes and Repo's connection pool. Brief row locks protect an event/binding/batch or PR, not every operation by one agent. HTTP and session calls execute after reservation commits and before a generation-checked result commit. A supervised WebSocket owner is justified by a live socket; it performs no serialized general SQL query service. No global `GenServer.call` query broker, global actor-row write gate, or one process required per board row. Oban's queue concurrency is per pod, so shared rate budgets/reservations enforce provider-wide limits across replicas.

Alternative: run the fleet connector in the farm01 pod. Rejected: it cannot safely reach a user's local sessions and would couple session transport to the dashboard. Alternative: only a launchd polling script. Useful supervision, but insufficient for receipts, fencing and recovery.

### D3. Durable resources and source capture

Names describe proposed boundaries, not generated migration/module names to copy blindly.

| Resource | Minimum durable contract |
| --- | --- |
| WorkerSubscription | Stable agent ID, authorized repository/goal scope, subscription revision, enabled/paused state, priority classes, enrollment start and bootstrap policy |
| WorkerBinding | Agent + host + adapter + native session identity; binding epoch; runtime capability results; explicit desired state; scoped credential reference |
| CooperationEvent | Unique `(source, source_key, source_version)`; type/priority; task/repo/PR/Context/Mattermost references; actor evidence; bounded fact summary; capture/routing state |
| WorkerDelivery | Unique event/recipient; pending/received/handled disposition; next eligible time; suppression reason; retained evidence; no destructive consumption on read |
| DispatchBatch / Attempt | Immutable selected delivery IDs and payload hash; random batch/attempt IDs; binding epoch; dispatch fencing generation; transport/receipt state; timestamps/errors |
| DeliveryReceipt | Exact agent, delivery, batch, epoch and attribution; first received/handled time; idempotency key; optional board progress/blocker references |
| MattermostOutbox / TaskThread | Unique lifecycle event/destination intent; durable root-post mapping; expected event marker; remote result or uncertainty; independent retry state |
| SharedBotAttribution / ConversationCoverage | ONE shared bot posts; per-agent attribution from structured post props (`agent_id`, `task_id`, `kind`, `msg_id` plus retry key) and header line; exact post/version coverage receipts per agent per channel (phase 1; phase 2 elastic bots swap in transparently) |

Task events and Context publications insert a source intent in the same transaction as their canonical write. A failure to insert rolls back both. The routing worker selects pending source intents by state and unique recipient ledger, not solely `id > cursor`. Persist bounded continuations and a pinned audience/routing revision; restart completes unfinished fan-out rather than skipping it. Joining workers receive a bounded bootstrap of current owned/assigned tasks, unresolved PR obligations and recent scoped Context, with explicit truncation/fetch links. They do not receive every historical channel post as fresh work.

Existing records get an explicit migration cutoff plus idempotent bootstrap/backfill. LISTEN/NOTIFY, server watch streams and socket events merely invalidate/wake; startup/reconnect and periodic durable rereads remain authoritative. Database sequence IDs are not commit order. A lower-ID source committing after a higher-ID route must still be selected. Existing Context receipts remain authoritative for context handled through either CLI or runtime; runtime acknowledgement and the matching Context receipt commit atomically. Previously acknowledged entries are not reintroduced as new pending work.

### D4. Delivery attempts, receipts and uncertainty

Delivery provides at-least-once opportunities with idempotent handling receipts. It cannot promise exactly-once execution across a terminal/HTTP crash boundary.

1. Lease one binding's next eligible batch with a random attempt ID and monotonically increasing dispatch generation. Freeze at most 20 event IDs / 16 KiB of UTF-8 prompt data, excluding full logs/docs; include fetch links and exact IDs for omitted items. Priority fairness preserves older ordinary work after urgent items. An event arriving after the batch freezes belongs to the next batch or a separate supported priority boundary frame.
2. Commit reservation before contacting a session. Default dispatch lease is 120 seconds with bounded renewal while the connector is alive; it is unrelated to the two-hour task lease. Once submitted, an attempt remains in flight awaiting explicit receipt even after reservation expiry; expiry alone does not prove non-delivery.
3. Deliver a frame with `batch_id`, `attempt_id`, `binding_epoch`, ordered event IDs, source references and the shared reconciliation protocol. Submitted bytes are transport evidence only. An adapter receipt proves a frame entered the selected session boundary, not that the model handled its contents.
4. The agent explicitly acknowledges exact event IDs after handling them. Idempotent retry retains the original attribution/time. `handled` permits a recorded blocker, defer reason or deliberate handoff; unresolved underlying tasks/CI obligations stay open. A generic turn-ended/idle observation cannot acknowledge a batch. Native turn completion provides health correlation, not automatic success.
5. If submission may have happened but no trustworthy result exists, persist `delivery_uncertain`. Reconcile explicit receipts, the native session/batch correlation where supported, and authoritative current state. Do not send a second prompt just because a timeout, lease expiry or idle badge appeared. Lack of provable reconciliation becomes a visible captain action, not a silent retry or lost item.
6. A retry only occurs after evidence of non-submission, a documented replay-safe adapter path, or an explicit retry decision. Duplicate frames require the worker to inspect handled IDs and current source state before acting. A stale batch never authorizes repeating a task mutation/PR repair.

Only the live binding epoch/attempt generation may apply new transport or handling effects; a late stale result cannot overwrite committed evidence. This fences board state, not an already-issued external call: old connectors must cancel on epoch loss and uncertain effects remain visible. Exact receipts for a terminal older attempt in the same epoch remain durable evidence, including same-key retries, but cannot acknowledge deliveries or canonical sources, rewrite the historical outcome, or release newer dispatch custody. Old-epoch receipt/result writes remain rejected. Historical reconciliation is evidence-only and never permits replay; validated canonical non-submission evidence can retire an old host journal without new native I/O. Unhandled rows remain discoverable regardless of numeric ordering.

Server clock defines dispatch eligibility and lease expiry; source timestamps remain source evidence. Pending/uncertain items are retained until explicit disposition. Completed attempt detail defaults to 90 days; retain source/delivery idempotency tombstones as long as the associated source can be replayed. Retention never deletes task/Context/document history or unhandled obligations.

### D5. Herdr is a transport; native adapters own stronger boundaries

Bind from the actual session with explicit host/server identity, opaque pane handle, harness and native session identifier where available. Do not infer identity from pane title, display name, model name or currently focused pane. The host service pins a configured socket/session, negotiates protocol capabilities, subscribes then reloads authoritative state, and validates the occupant immediately before dispatch. Rebind requires an explicit new epoch after pane/session replacement; ambiguity disables prompting. Herdr cannot retire board agents or reclaim leases.

| Adapter tier | Initial behavior | Stronger path and required proof |
| --- | --- | --- |
| Herdr transport | Observe a verified idle/done occupant; submit one bounded frame; require CLI/API receipt | Socket subscriptions help scheduling. `agent.prompt --wait` is lifecycle evidence, not a batch-specific completion receipt. |
| Claude | Same safe Herdr delivery when bound | Dedicated Stop/session-start hooks and supported tool boundary integration; hooks coexist with user/Herdr/Firstmate hooks and have one wake owner. |
| Pi (including GLM) | Same safe Herdr delivery | Extension owns resume/new/fork generations, turn events and supported tool-result additions; exact session replacement retires old callbacks. |
| Grok | Same safe Herdr delivery | Native tracked background completion only after installed interactive harness proof. No shell `&`; headless output wake is not assumed. |
| Codex | Same safe Herdr delivery; explicit bounded foreground checkpoint fallback | A supported infrastructure-tool/MCP wrapper returns pending priority frames. No assumption that detached/background waits resume Codex. App/CLI surfaces are separate capabilities. |
| Muse / AGY / other harnesses | Herdr delivery plus explicit check-in/receipt, if binding proof succeeds | Native hooks and mid-turn delivery remain unsupported until a versioned executable/adapter contract passes. Model brand is not a harness capability. |

Never send terminal input to `working`, `blocked`, `unknown`, paused or identity-mismatched sessions. Native tool-return delivery can be supported while working because it is inside the harness execution boundary; that is distinct from typing into a busy terminal. Never answer an approval dialog automatically. A user-composed prompt or intervening user turn defers dispatch. The Herdr adapter must verify a machine-readable safe-input contract on the installed version; if occupied composer detection cannot be proved, automatic Herdr submission stays disabled and the dashboard offers manual check-in. This limitation is a rollout gate, not an assumed capability.

The proposed `worker install` previews changes, merges owned hook entries without replacing existing files, writes a versioned configuration/backup and service definition, and reports restart/reload requirements per adapter. `worker doctor` proves connectivity, binding, hook version and receipts; `worker pause/resume/unbind/uninstall` preserves pending work and removes only integration-owned files. Skill installation remains a separate command with no implicit service start. launchd `KeepAlive` or systemd restart owns the daemon; agents do not repeatedly arm host watchers from memory.

We are not currently executing inside a verified Herdr-managed pane, so no live pane inventory or control was used to validate this proposal. Official protocol docs and installed CLI help establish candidate seams; the installed-server schema and isolated live conformance tests are mandatory before enabling that adapter. Do not silently bypass this with an inherited/default focused session.

### D6. Priority and participation policy

Ordinary lifecycle/channel events queue for the next eligible turn. Urgent DMs and new scoped peer Context can be added at supported **infrastructure-tool return** boundaries, preserving the original result and clearly delimiting untrusted source text. Existing CLI stdout/NDJSON/watch payloads remain unchanged; use dedicated worker/check-in tools or an explicit MCP boundary adapter, never append prose to arbitrary CLI JSON. No wrapper claims to inject into all shell returns or interrupt a running process.

Default batching coalesces by source revision; receipts use exact IDs. Context/channel summaries are bounded with full-detail links; prompt overflow stays pending, and repeated high-priority traffic cannot starve ordinary work. Subscription filters are explicit per repository/authorized goal; relevant peer entries are shared across that scope, not just the current task. Task-specific UI filtering is a separate display concern. Ignore self-origin context notifications and bridge echo sources when already seen.

Idle continuation defaults to ten minutes, with at most one outstanding reminder per binding. Eligible workers must be enrolled, enabled, safely idle, within an authorized goal with unresolved responsibilities, and not paused, approval-blocked, quota-exhausted or in an adapter failure cooldown. A no-Context reminder is at most once for a completed work turn that recorded substantive progress; it invites a useful finding or explicit no-new-finding disposition. It never forces fabricated facts or a repeated empty-publication loop. Provider/model outages and repeating no-progress turns enter bounded cooldown and a visible reason. Human pause is durable and suppresses every automatic wake path, including hook callbacks.

### D7. Mattermost lifecycle bridge, then genuine worker conversations

The first bridge uses one `agentboard` bot for lifecycle notifications. One durable thread mapping per task, short events carrying actor/model/harness and board/PR links, no heartbeat flood. Task state and an outbox intent commit together; network delivery is asynchronous. Handoff in `board` mode retains the existing board message; `dual` adds the outbox; `mattermost` writes assignment/event/outbox without requiring a board chat row. Recipient acceptance still requires an explicit claim.

Phase 1 posts every agent message through the ONE shared `agentboard` bot; agents never hold Mattermost credentials and `agentboard chat send/read` calls the Agentboard API. Each post carries per-post `override_username` (the agent id), `override_icon_url`, structured props (`agent_id`, `task_id`, `kind`, `msg_id` plus retry key) and a readable `[<agent-id> · <task-id>]` header line. Props are the source of truth, never the display name. Addressing uses plain `@agent-id` text mentions; inbound routing parses them, and thread replies route by the thread root's props. The code works with `EnablePostUsernameOverride`/`EnablePostIconOverride` off (header plus props carry identity); the runbook lists the flip as a captain decision. Phase 2 (GH #82, not blocking `dual` mode) creates an elastic bot per agent lazily on first `agent register` with AshCloak-encrypted tokens in Postgres, retired by roster GC; the server posting seam stays pluggable so the swap is transparent. No per-agent k8s secrets, no tokens in Git or board records. Human peer messages retain their actual user identity. Workers send/read through dedicated conversation commands/tools; do not overload Context with chat. Inbound `/board` slash commands remain a separate later PR with token and user allowlist, and are not required for peer DM delivery.

The server listens on Mattermost WebSocket plus REST catch-up on workers' behalf. Source IDs are `(server_id, post_id, update_version)`; own sends (matched by `props.agent_id` plus `msg_id`, since every post shares the bot user) and lifecycle echoes do not cause wake loops. Persist references, channel/root/sender IDs, hashes, source times and recovery state in the board delivery ledger. Bodies remain authoritative in Mattermost; bounded server-side spool may retain unsent outbound content or received bodies until durable ingest, with restrictive permissions and configurable expiry. It is not BM25-indexed or exposed as a second inbox. Edits get explicit versions; deletions/unavailable membership produce a source-unavailable disposition, never invented content.

Subscribe before catch-up, buffer live arrivals, page through authorized channel/DM history with overlap, persist exact post/version IDs and reconcile duplicates. Save catch-up coverage/time and unfinished page jobs; websocket sequence is not a durable history cursor. Recovery repeats overlapping pages and anti-joins receipts, including updates/new channels discovered after downtime. Test same-millisecond posts, multiple pages, concurrent arrivals and edits. If retention/permissions/API ordering prevent demonstrating a closed gap, expose `catch_up_incomplete` and stop declaring the worker caught up; do not silently advance a timestamp. Enrollment sets a documented history start rather than replaying all old chat.

Outbox uniqueness protects local intents. A remote accepted-post/lost-response case is different: persist an event marker in post props and reconcile complete allowed history/root mappings before retry. Do not treat client `pending_post_id` as proven server-side idempotency. If ambiguity cannot be resolved, park visibly rather than blindly POST again. Automatic exactly-once remote posting is not promised without an independently verified receiver-side idempotency contract; choosing availability by manual retry records that decision and possible duplicate. Reconcile/flag duplicate roots rather than hide them. Initial acceptance explicitly exercises accepted-then-timeout, retries, lease loss and duplicate jobs.

Message mode is operator-controlled: default `board`, then explicit `dual`, then `mattermost` after evidence. Cutover is gate-based, not a fixed calendar duration. The final mode routes new conversation tools to Mattermost; legacy board reads/recipient acknowledgements and export remain available, legacy sends return a clear migration response, and the primary Messages nav/task thread become Mattermost links plus historical read-only archive. Pending legacy direct messages remain individually actionable until handled or explicitly migrated. Rollback re-enables board writes and keeps outbox/remote receipts; it neither deletes history nor blindly mirrors all chat back into PostgreSQL.

### D8. Scoped runtime capabilities without pretending the legacy board is authenticated

Existing board coordination is trusted-network/identity-attribution, not full authentication. New enrollment/binding/dispatch/receipt operations require a separately provisioned scoped runtime credential or an authenticated proxy identity mapped to it. A host credential is restricted to its configured worker IDs and repository scopes; each local session gets a worker-scoped receipt capability, not the host-wide secret. Captain capability gates provisioning/rebinding; actors cannot choose another recipient or extend authorization scope through event text. Tokens are references in config, read from protected storage, redacted from errors, and never passed as command-line values or embedded in HTML.

Messages and findings are evidence from named sources, not authorization to execute commands. Only enrolled scopes and existing user authorization determine action. A wake can ask an agent to inspect an already-submitted PR; it cannot approve a merge or reclaim an expired claim. Credential revocation/epoch change disables new dispatch and callbacks. This does not secure old unauthenticated routes against an untrusted network; deployments must retain the current trusted network/proxy boundary until separate board authentication work lands.

### D9. PR accountability and dashboard visibility

The existing Ash/CI change owns provider collection, freshness/current-head truth, failure-episode identity, follow-up tasks and completion guards. This change owns delivery of those durable follow-ups. Its observation/follow-up stages are the first implementation dependency, not postponed until all Mattermost work is finished. Connect the atomic failure-observation/follow-up transaction to a source intent; do not create a second failure-episode engine in the connector or poll providers from each agent host. Fixtures support development; first-release acceptance also requires a real controlled failing PR.

Poll registered open PRs continuously in the server, including ones linked from terminal/archived tasks and previously green PRs until merged/closed or explicitly unmonitored. Default due interval is 60 seconds subject to shared provider budgets/backoff; immediately schedule a newly linked PR. Observe current head, complete check/status pages and latest attempts. Partial/error/missing-policy observations remain unknown/degraded; they cannot silently produce a green verdict. Confirmed current-head failure produces one active episode/repair obligation with check/job links and bounded available diagnostics. BuildBuddy enriches evidence when configured; denial/outage cannot suppress a GitHub failure alert. Broad completion guards and richer diagnostics still follow their existing tasks; early delivery is not a waiver.

Initial recipient is the canonical PR's recorded responsible submitter; intentional responsibility handoff is durable and distinct from mutable current-task pointers. Multiple submitter/conflicting provenance needs explicit responsible-agent resolution, not a guessed pane or GitHub username. Unknown/unavailable responsibility appears in the captain queue. Moving to a new issue, lease expiry, stale heartbeat or source-task completion never transfers or erases that accountability automatically. Explicit task/repair handoff updates the active obligation recipient with history; stale original owners do not trigger takeover.

CI failure alerts are high-priority infrastructure events in this deployment (an adaptation to the paper's generic router): supported native/tool boundaries deliver them while a worker is active; verified Herdr transport defers until safe idle. Acceptance targets first delivery within two minutes of a confirmed failure when an enabled verified boundary and provider/service budget are available. Busy-only fallback, rate limiting, pause and outage disclose the actual delay instead of violating safe input to meet a timer.

Acknowledging an alert does not disable monitoring/reminders for the repair obligation. Default reminder is due after 15 minutes without a recorded repair/blocker/handoff update while the failure remains current; coalesce one per obligation/reminder generation. At most four reminder wakes per hour, then retain a captain escalation and hourly digest while unresolved. A meaningful recent progress update postpones the next reminder without declaring repair; an explicit blocker retains a visible blocked/escalated obligation instead of repeated wake spam. Human pause suppresses agent prompting, while captain visibility remains. These are deterministic timers on obligations, not another model deciding who should work. No-progress acknowledgement alone is not progress evidence.

Example: worker A links PR X, moves to issue Y, and X later fails at head H. One episode/obligation and one delivery intent are recorded. A's next safe boundary receives exact PR/head/job/evidence links. A can record repair or a blocker and acknowledge notification; the PR row remains failing until the monitor verifies a qualifying latest result. If A restarts, the same pending obligation survives. If the receipt was already handled, a new CI failure episode can still produce a new wake. Green recovery suppresses obsolete pending alerts by current-state reconciliation; it does not silently complete follow-up tasks.

Task detail adds read-only **Shared context**: 20 recent task-linked entries, kind/summary/source/time and filtered `/context` link; no reads acknowledge findings. Documentation stays clearly named as rendered artifacts and timeline as events. Reuse existing Context domain filters, bounded pagination and escaped rendering; a Context failure displays a section error rather than hiding the task.

Existing `/agents`, task and planned `/prs` views show responsible identity/host, active binding/capabilities, pending count/oldest age, last received/handled, source/provider health, pause/approval/cooldown/uncertainty and follow-up links. Avoid a new fleet UI or widening every Kanban card. Heartbeat freshness is distinct from connector health, adapter readiness, task lease and CI freshness. Issue #42 owns retirement/stuck-busy roster policy; its stale rows are never treated as live ownership merely because `current_task_id` remains set.

### D10. API and command seams

All paths/commands in this table are proposed and must be added to the versioned API/CLI documentation with schema negotiation before use. Existing endpoints retain their pagination/watch/error/429 contracts.

| Interface | Contract |
| --- | --- |
| `/api/v1/workers/...` enrollment/binding/state | Scoped authentication, revision/epoch checks, desired pause state, explicit capabilities/unsupported reasons |
| Worker pending/check-in reads | Bounded pages; every relevant item has immutable ID and source link; read never acknowledges; return more/catch-up health |
| Dispatch reserve/submit-result/reconcile | Immutable batch membership; operation idempotency key; epoch + attempt generation; conflict on stale writer |
| Exact receipt action | Received vs handled; exact item IDs; worker-scoped capability; idempotent attribution; compatible Context receipt transaction |
| Dedicated worker watch | Invalidation/health only with reconnect reread; does not reinterpret existing task/msg watch NDJSON |
| `worker install/doctor/serve/bind/pause/resume/unbind/uninstall` | Explicit activation; profile/version reporting; service/hook ownership; protected token references; no global skill install side effects |
| `worker check-in/ack` and conversation tools | Machine-readable stdout, cancellable bounded retries, no uncertain-write replay; escaped boundary frame is a dedicated output format |

Default host fallback poll 30 seconds, server reconcile 60 seconds, reconnect exponential jittered 1–60 seconds respecting a longer provider `Retry-After`. Provider budgets apply independently of retry queues. 429, 401/403, incomplete history, model outage and source deletion remain explicit states; stale/error evidence cannot appear as delivered/green. No background sleep holds a Repo transaction or blocks dashboard work.

## Risks / Trade-offs

- [Terminal delivery is not atomic with a ledger commit] → Persist uncertainty, use explicit receipts and capability-specific reconciliation; prefer visible unresolved delivery to automatic duplicate prompts.
- [Herdr may not expose a safe composer/session contract on the installed server] → Gate automation on live conformance; use explicit check-in/native adapter instead of claiming universal unattended support.
- [Hook ownership conflicts or recursive Stop continuation] → Integration-owned namespaces/backups, one selected wake owner, durable pause and bounded no-progress cooldown; test existing Firstmate/Herdr hooks remain intact.
- [Chat outage or accepted-post uncertainty] → Separate queues/outbox, async handoff, complete catch-up and uncertainty parking. A shared CNPG outage remains a common dependency, not isolated by separate application supervisors.
- [Context fan-out/prompt growth] → Repository-scoped enrollment, bounded frames, exact receipts, fair priority and explicit truncation; do not copy full histories into every prompt.
- [Agent receipt is false assurance about work completion] → Retain underlying CI/task truth and evidence independently; expose both states in UI.
- [Legacy trusted-network actors are attributable, not authenticated] → Scoped new runtime capabilities and existing network boundary; do not market this as a full board auth solution.
- [Too much scope in one PR] → Ordered independent release gates below; every PR leaves the current primary inbox usable.

## Migration Plan

1. **CI observation and visible ownership:** complete the necessary existing Ash/CI provider/reservation/failure-obligation tasks with a compact responsible-agent/CI row and source-intent capture. Observe before notifying; keep board primary. Record old spec conflicts without removing contracts.
2. **CI delivery core and one proven adapter:** add scoped runtime resources/receipts, supervised host service and one real safely bound session. Validate Herdr safe-input support; if unavailable, implement a known supported native path (Claude/Pi) instead of treating manual check-in as automatic success. Demonstrate a controlled failing PR after its owner moves to another issue, receipt, overdue reminder/escalation, restart recovery and successful repair. This is the first release gate.
3. **Outbound Mattermost bridge:** additive outbox/thread mappings, bot/Secret/channel preparation and independent queue. Prove multi-pod duplicate jobs, late commits, outage catch-up and accepted-post uncertainty. CI delivery continues directly through the worker API even if Mattermost is down.
4. **Worker identities and conversations:** independent worker bots/REST/WebSocket/tools. Run `dual`; prove two workers can send/receive/handle channel and urgent DM traffic headlessly through downtime. Existing legacy unread items remain recoverable.
5. **Context/native boundaries and fleet enrollment:** task Context clarity, scoped findings delivery, Claude/Pi boundaries, Codex/Grok capability-specific paths and verified Muse/AGY fallback. Test each installed version/session generation; report each of the six workers' actual capabilities and gaps, not blanket parity. Finish remaining CI guards/diagnostics through the existing proposal in parallel with these later releases.
6. **Cutover:** only after peer identity/DM/catch-up, handoff outbox, supported delivery, historical inbox and rollback gates pass, select `mattermost`. Reconcile `board-messaging`, `agent-workflows`, related handoff requirements, README/PRD #1/#37/#41/API/skills with new authoritative transport. Never archive contradictory specs as simultaneously current.

Rollback disables dispatch and bridge jobs through runtime fences, pauses host services/hooks and selects `board` mode. Leave additive tables, historical messages, pending items, receipts, Context and HTML intact. Re-enable only after reconnect reconciliation; do not rewind a numeric cursor or recreate a second active binding. Each implementation PR fetches fresh main, runs appropriate remote acceptance, includes Archify + portable Lavish documentation and a live task link. Production enablement requires measured evidence, not a checked planning task.

## Open Questions

No unresolved architectural choice blocks this proposal. Deployment-time values (host names, Mattermost team/channel IDs, actual adapter versions and credential references) are enrollment inputs. Installed Herdr safe-input/session correlation and harness boundary support are explicit conformance gates with defined fallback, not assumptions. Outbound bridge uses one service bot; peer messaging uses per-worker bots; dual-run ends on evidence; all prose conversation moves to Mattermost, with legacy board history preserved read-only.
