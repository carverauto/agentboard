# Design

## Context

See [proposal.md](proposal.md) for motivation and scope. The source of product intent is [issue #1 and its captain comments](https://github.com/carverauto/agentboard/issues/1). The user selected full M1–M3 coverage, stable caller-chosen IDs, a two-hour default claim lease with explicit renewal, and manual expired-claim recovery.

Observed implementation is foundation only:

- The original `cmd/ab/main.go` stub prints “not implemented” and exits 2; `go.mod` contains no application dependencies.
- `web/` contains only README and a placeholder filegroup. There is no Phoenix app, migration, API, or design system to preserve.
- Bazel has Go tooling, a pinned Go SDK, an RBE platform, and remote profiles. `buildbuddy.yaml` builds the stub and filegroups, with no application tests or Phoenix packaging.
- Kubernetes already specifies dedicated TLS-only CNPG, DB/role/namespace `agentboard`, migration release entrypoint, port 4000, health probe paths, nonroot/read-only containers, and a farm01 HTTPRoute. Images still use `build-required`.
- Issue comments confirm the hostname, storage class, PostgreSQL pin, and route ownership. Read-only inspection of `~/src/gitops/clusters/farm01/manifests/envoy-gateway.yaml` confirms the checked-in listeners cover k8s-farm.carverauto.dev; its cert-manager issuer solver also restricts that domain. This is repository evidence, not a fresh cluster verification.
- Local installed quota-axi types and Firstmate's `bin/fm-quota-axi-lib.sh` confirm `schemaVersion`, `providers[].windows`, schema 6 `accountKey`, and scope summaries under `quotaSemantics.effectiveAvailability`. No live quota or credentials were read.

## Goals / Non-Goals

**Goals:** Keep the write contract small enough for a thin CLI, enforce concurrent ownership in the database, make state/history atomic, and let notifications accelerate reads without becoming authoritative. Deliver in M1/M2/M3 increments with matching remote smoke checks.

**Non-Goals:** See proposal exclusions. In addition, there is no direct database access from agents, durable streaming consumer protocol, automatic lease sweeper, dashboard write surface, or hard delete command in v1. “CRUD” in the PRD means creating/reading/editing and lifecycle cancellation here; history survives cancellation.

## Decisions

### 1. Phoenix API owns all database access

The user's API-only correction supersedes the original direct-database direction. The Go CLI uses net/http and a maintained argument library; organize internal/config, internal/client, internal/output, and focused commands. Configure AGENTBOARD_URL (default https://agentboard.farm01.carverauto.dev), overridden by --url, and optional AGENTBOARD_CA_FILE/--ca-file for a private HTTPS CA. Verify certificates and hostnames; allow plain HTTP only for loopback development/test addresses. Agents receive no database URL, password, or CNPG CA material.

Phoenix serves /api/v1 alongside the read-only LiveView dashboard in namespace agentboard. Ecto owns migrations under web/priv/repo/migrations, applied only by Agentboard.Release.migrate(). Contexts provide validated API reads and invoke database mutation functions for transactional lifecycle/event creation. The same read contexts serve LiveView, ordinary API queries, and watches. There is one externally supported write path. Database row locking still decides simultaneous claims; HTTP does not weaken ownership guarantees.

Board contexts are ordinary modules: API controllers, stream processes, and connected LiveViews call Ecto.Repo directly in their own BEAM processes, using the configured Postgrex/DBConnection pool (default 10 connections). No application-wide GenServer, Agent, global lock, or mailbox serializes SQL queries, mutations, quota projection, or snapshot generation. Task row locks serialize only competing mutations of the same task; independent tasks/reads proceed concurrently. The notification listener owns only its LISTEN connection and publishes compact invalidations; it never executes board reads or handles synchronous query calls. ETS limiter checks use atomic table operations in the request process; its supervised owner manages table lifecycle/cleanup only. Each runtime process has an explicit state/connection/lifecycle reason and supervision strategy, following installed elixir-thinking/ecto-thinking/phoenix-thinking/otp-thinking and ServiceRadar's no-process-without-runtime-reason guidance. ServiceRadar-specific Ash/platform-schema/migration commands do not apply to this independent Ecto app.

API routes include GET /api/v1/meta (API and schema compatibility), resource GET lists/details, POST /agents/register and /agents/:id/heartbeat, POST /tasks, PATCH /tasks/:id, POST /tasks/:id/{assign,claim,renew,release,reclaim,update,link,handoff}, POST /messages, POST /messages/:id/read, POST /quota, and GET /{tasks,messages,quota}/watch. Resource paths above are relative to /api/v1. Writes carry validated X-Agentboard-Agent, X-Agentboard-Model, and X-Agentboard-Harness headers; unknown/mismatched identities fail before durable mutation, except registration creates an identity. Caller-scoped reads use the agent header. Bodies are JSON with bounded size (5 MiB); responses reuse the stable record/list envelopes. API errors use {"error":{"code":"...","message":"..."}}: 400/422 invalid input, 404 missing record, 409 ownership/state conflict, 429 rate_limited, 503 database/schema unavailable. Do not expose SQL or credentials in errors.

Install a rate-limiting plug on the API pipeline ahead of body parsing and database work. Use a supervised, bounded ETS fixed-window limiter with configurable defaults of 120 requests/minute per connection-source IP and 60/minute per declared agent. Health probes and browser routes are outside this pipeline. Missing-agent requests still incur the IP limit; per-agent limits are collaboration controls, not authentication. Trust no arbitrary forwarded-IP headers; use connection remote_ip unless an explicit trusted-proxy configuration supplies the client address. Return structured 429, Cache-Control: no-store, and positive integer Retry-After seconds without invoking the mutation. Document limits as per Phoenix replica; v1 is one replica. Garbage-collect expired buckets and fail closed with 503 if limiter capacity is exhausted. Cap active watch streams separately (default 5/agent, 20/source IP) and release reservations on disconnect. This avoids a Redis dependency while bounding abuse and explicitly acknowledges scale-out aggregate limits.

The CLI honors both Retry-After delay-seconds and HTTP-date formats. Wait at least the advertised interval, with positive jitter; absent/malformed values use bounded exponential backoff. Ordinary requests have a 120-second total deadline and at most three retries after 429; a delay exceeding the remaining deadline yields a clear infrastructure/rate-limit error rather than an early retry. Waiting is cancellable and diagnostics stay on stderr. Do not automatically retry non-429 mutation failures, including connection loss or ambiguous responses; inspect durable state before repeating. Reconstruct request bodies for each safe 429 retry. API redirects are rejected, avoiding unreviewed replay or caller-context forwarding to another host. Streaming handshakes also respect 429; once connected, server fallback refreshes do not generate repeated client API requests.

Direct DB clients were rejected by the user. A separate API service would duplicate deployment/runtime overhead; embedding endpoints in Phoenix reuses its release, contexts, probes, private Gateway TLS, and pool. Authentication remains out of v1 scope, so declared identities provide attribution rather than proof of identity.

### 2. Schema increments and attribution

M1 creates agents, tasks, task_events, and a schema-version marker. M2 adds messages and notification triggers; M3 adds quota reports and their provider/window/scope projections. Each migration is versioned and additive. The API enforces feature/schema compatibility and reports it through /api/v1/meta and structured errors; CLI commands never connect to or migrate the database.

Retain the PRD's task/agent fields and indexes, adding:

- Nonempty immutable slug IDs; uniqueness and foreign keys. Agent registration may update metadata/model for an existing matching harness; a different harness must choose another ID.
- Required actor/model/harness for attributed operations. Optional session backend remains metadata, e.g. `harness=codex, backend=herdr`. Historical values are snapshots, not joins to today's model.
- Task revision for guarded metadata/status writes, `assigned_by` for pending assignment management, and assignment/claim timestamps with state checks.
- Append-only task_events with old/new revision and relevant changed fields. Reject updates/deletes to these events through database guards. No task hard deletion/cascade path is exposed.
- Registry write provenance for registration and heartbeat; message sender/read-action provenance; quota source provenance. Idempotent no-op operations do not create false mutation events.

The PRD schema allows nullable model/harness, while its goals require them on every write. New writes follow the goals and fail clearly on missing context; there is no legacy data to migrate. These are collaboration checks on a trusted network, not identity authentication: a trusted-network API caller can supply another agent ID; database credentials remain server-side.

### 3. Exact ownership and transition contract

Database time decides expiry, with `claim_expires_at <= clock_timestamp()` meaning expired. Capture one operation time after obtaining the relevant row lock and reuse it for the mutation/event. A claim lasts two hours unless the caller supplies a positive `AGENTBOARD_CLAIM_TTL`. The configured duration is recorded in the claim event.

| Operation | Allowed state and actor | Result |
| --- | --- | --- |
| create | Any registered actor, unused ID | open; no owner or lease |
| assign | Any actor on open work; assigner or assignee on assigned work | assigned to registered target; no lease |
| claim | open/unowned, or assigned to caller | in_progress; owner caller; lease starts |
| renew | Unexpired owner of in_progress/blocked/review | Same state/owner; expiry becomes operation time + TTL |
| release | Pending assignee; unexpired owner; any actor explicitly recovering expired active work | open; clears owner, assignment, and lease fields |
| reclaim | Explicit operation by any registered actor on expired in_progress/blocked/review | in_progress; new owner/lease; prior owner recorded |
| handoff | Unexpired owner of active work, registered target, nonempty note; M2 | assigned to target; clears lease; event + direct message |
| edit/link/note | Any actor on open work; assigner/assignee on assigned work; unexpired owner on active work | Same ownership; revision/event advances |
| cancel | Any actor on open/assigned work; unexpired owner on active work | cancelled; retains historical assignee; clears live lease |

Generic status commands permit only:

- `in_progress -> blocked | review | done | cancelled`
- `blocked -> in_progress | review | cancelled`
- `review -> in_progress | blocked | done | cancelled`
- `open | assigned -> cancelled`

Entering blocked requires a nonempty reason. Terminal tasks are immutable in v1, including metadata/ownership, although peers may continue posting task comments. Ownership commands supply the open/assigned/in_progress transitions. Completion/cancellation clears live lease fields; history retains their previous values.

Assignment has no lease until accepted. The issue's sample SQL would reject a valid assignee because `assignee_id` is nonnull and no expiry exists; acceptance explicitly handles `status=assigned AND assignee_id=caller`. A normal claim never steals or recovers an expired active task: explicit reclaim or release is required. Expiry does not change status. Heartbeat is independent and never extends a lease.

Mutation functions lock the task, validate actor/state/expiry, condition updates on current revision/state, and append the event before committing. Two normal claimers produce one success and one conflict. A stale caller cannot mutate after ownership changes or the lease expires. Retrying an already-live claim is a conflict; renew is its explicit operation.

General lease release is not a distributed filesystem lock: the board cannot halt a former worker's external activity. Workers must verify ownership before meaningful steps and stop if renewal fails.

### 4. CLI contract and error behavior

Explicit `--agent`, `--model`, and `--harness` take precedence over `AGENT_ID`, `AGENTBOARD_MODEL`, and `AGENTBOARD_HARNESS`. Reads require only the API URL/HTTPS trust configuration except caller-scoped inbox reads. All writes need full context; registration creates the identity. The captain uses a registered shell/assistant identity for attributed commands.

Commands are:

- Agents: register/list/show; heartbeat with busy/idle and optional owned task.
- Tasks: create with optional `--id` (otherwise readable title slug + collision-resistant suffix), list/show, edit, assign, claim, renew, release, reclaim, update note/status, link, and M2 handoff/watch.
- Messages: send/list/read/watch, including recipient-less `send --task` comments.
- Quota: push/list/watch; push accepts stdin or `--file`.

Accept documented PRD flags; additional lease/edit/reclaim operations make its workflows concrete. Validate nonnegative integer priority, nonempty titles/body as appropriate, known statuses, slug format, TTL duration, and HTTPS github.com issue/PR URL shape. Read URLs are links only.

JSON lists use `{"tasks": [...], "next_cursor": null}` and equivalent agents/messages/quota envelopes; show uses `{"task": {...}}` or `{"agent": {...}}`. Mutations with `--json` return the resulting record and event/message identity as applicable. Use UTC RFC3339 timestamps, snake_case names, explicit nulls, and stable ordering: tasks priority then updated_at descending then ID; feeds timestamp then numeric ID. Default page size is 100, maximum 1000; opaque keyset cursors preserve filters. Reads never imply hidden completeness; cursors indicate remaining rows.

Failures write a concise diagnostic to stderr, with exit 2 for invalid input/context, 3 for not found, 4 for state/ownership conflict, and 1 for infrastructure failure. JSON error mode emits a stable error object on stderr. Stdout remains records only. HTTP status/errors map to these same exit codes; exhausted 429/deadline and server failures use exit 1. Cancelled writes after an uncertain commit are not blindly retried; users can inspect task/show and the event log.

### 5. Durable messaging and handoffs

Messages follow the PRD destination check: recipient or task is required; direct messages may also carry task context. Inbox reads default to the caller and do not mark messages read. Task feed reads include direct messages with task context because this is a shared trusted board, not private messaging.

Only the recipient may set first-read timestamp, recording its read attribution. A recipient-less task comment has no global read state. Handoff locks the task and persists assignment, event, and a message as one transaction; a message failure rolls back the ownership change. M1 supports assign/release; full handoff ships with M2's message schema.

### 6. Notifications are invalidation hints; watches return snapshots

M2 installs transactional triggers publishing compact IDs to `ab_agents`, `ab_tasks`, `ab_messages`, and `ab_quota` as the corresponding features exist. Payloads contain topic/entity identity/revision where available, never bodies, secrets, or raw quota reports. Transaction rollback discards the notifications.

Phoenix runs one supervised dedicated PostgreSQL listener, broadcasting invalidations through Phoenix PubSub to connected LiveViews. Coalesce bursts and requery the affected read model; do not spawn an LLM or one DB listener per browser. Always resubscribe and reload after reconnect. M1 refreshes mounted views every five seconds; retain that fallback for missed notifications, listener outages, and time-derived heartbeat/lease flags.

CLI watches connect to Phoenix HTTP NDJSON snapshot streams. The server subscribes to PubSub before loading an initial snapshot and processes queued invalidations; only the supervised Phoenix listener uses PostgreSQL LISTEN. Task/message/quota watches emit refreshed complete filtered snapshots, not a promise of replaying every historical notification. In JSON mode each NDJSON line contains `topic`, `kind=snapshot`, `observed_at`, `reason=initial|change|reconnect|fallback`, and the list envelope. Phoenix gathers each logical snapshot from one consistent database read transaction before streaming it, so pagination does not silently omit rows; large fleets may need a future delta protocol.

Reconnect uses bounded backoff and Retry-After on 429, emits connection diagnostics on stderr, reopens the HTTP stream, and labels its first full snapshot reconnect. A five-second fallback checks persisted state if notifications are lost and recomputes lease flags. `agentboard task list --watch`, `agentboard msg list --watch`, and `agentboard quota list --watch` alias topic watches with the same filters. SIGINT/SIGTERM cancels the HTTP stream promptly; server disconnect cleanup releases watch slots and PubSub subscriptions.

Durable streaming cursors/outboxes were considered but exceed the fleet's current needs. Snapshot recovery handles missed changes without claiming exactly-once event delivery; historical task events remain independently readable.

### 7. Read-only captain dashboard

Create a plain Phoenix/LiveView/Ecto app under `web/`, with a focused Board read context. Routes cover board, task detail, agents, messages, and quota. Use status columns, compact cards, clear links, and bounded timelines/feed pagination. Use standard Phoenix assets/components with a small coherent theme during implementation; there is no existing product UI to match.

All reads use current rows and attributed timeline events. Expired claims and stale agents are separate computed labels. Escape user-supplied text; display external links safely. Empty, unavailable, and stale data have distinct states. Database query failures preserve last-known data with an unavailable label rather than replacing it with a healthy empty list.

The dashboard UI has no mutations, auth middleware, or external GitHub integration. Read-only is a v1 UI scope choice; the same Phoenix application exposes the complete write contract through its rate-limited API used by the CLI.

### 8. Quota reports preserve provider semantics

M3 stores the complete accepted report in `quota_reports` with schema version, generated_at, ingested_at, source agent/model/harness, and a canonical JSON digest. Unique `(source_agent_id, digest)` makes exact retries idempotent. Children represent one provider/account observation, its windows, and effective scopes. The report plus all projections commit together.

Schema 5 permits one row per provider and maps absent accountKey to default; schema 6 requires nonempty unique `(provider, accountKey)`. Preserve `accountKeys` aliases as producer metadata, not additional duplicated provider rows. Unknown provider identifiers are allowed if structurally valid. Require a valid generation timestamp and provider state/windows structure; validate finite numerical values, percentages in 0–100 when present, and unambiguous window/scope IDs. Reject unsupported versions/ambiguous duplicates atomically.

Project `percentUsed`, `percentRemaining`, window identity/reset, provider freshness/state, and `quotaSemantics.effectiveAvailability[]` including `effectivePercentRemaining`, `runway`, and `selection.spendPriority`. Missing fields stay null. Do not derive capacity for `shareOf` meters, ignore producer uncertainty, equate through_reset to infinite seconds, or synthesize a single reset across scopes. Preserve newer producer metadata in raw JSON for inspection without teaching the board to calculate routing.

Latest reads select the whole provider/account observation by generated_at, then ingested_at/report ID. Source agents refer to collection provenance, not extra account identities. Older arrivals remain history; newer empty observations supersede old windows completely. Highlight producer stale/unavailable state and observation age (default ten-minute age threshold, configurable); never silently reuse a formerly fresh number after a newer failure. History is append-only with no v1 retention deletion.

Default quota panel exposes projections, not raw provider JSON. The board never contacts providers, refreshes credentials, or starts work based on spend priority. Synthetic schema 5/6 fixtures should be constructed from inspected public types/adapter contracts, not copied live credential-bearing reports.

### 9. Remote delivery fits existing manifests

Extend Bazel to declare Go dependencies, Phoenix/OTP/Elixir tools, asset inputs, remote test targets, release packaging, and OCI image assembly. Pin toolchain/image inputs during implementation and execute dependency fetch/compilation/test/asset packaging on RBE. Existing platform images are not evidence that Elixir tools exist; establish a remote toolchain target rather than falling back to local Mix.

BuildBuddy CI replaces placeholder-only success with targeted Go, database concurrency/rollback, Phoenix, quota adapter, and packaging checks. Database integration tests use an isolated PostgreSQL service in the remote test environment, never the farm01 database. CI must record its isolation/cleanup method and actual invocation results.

Build static CLI artifacts for Linux/Darwin amd64/arm64 with checksums through remote cross-compilation, and a Linux dashboard release image under Harbor. Wire publication through repository automation; publishing/deploying are separate operator actions after build validation.

Runtime supports the current split DATABASE_HOST/PORT/NAME/USER/PASSWORD variables and optional DATABASE_URL override. Only Phoenix uses these DB variables and CNPG verified TLS/CA mounts. CLI hosts use AGENTBOARD_URL and Gateway HTTPS trust; expose no database service to agents. API and LiveView use the same private hostname, port 4000 service, and immutable release image.

Implement the existing release migration command and `/health/live`/`/health/ready` endpoints. Liveness checks the running process; readiness checks DB connectivity and required schema. Configure release temporary files under /tmp to fit nonroot/read-only manifests. Use the same immutable dashboard artifact for migrations and deployment.

Retain the chosen PHX_HOST and app-owned HTTPRoutes. Use the existing cert-manager and external-dns installations, as the user requested. Prepare a companion GitOps PR; this proposal edits neither GitOps implementation nor live infrastructure.

Inspected references under `~/src/gitops/`:

- `clusters/farm01/manifests/envoy-gateway.yaml`: shared private-LAN Gateway, wildcard and apex listeners, certificate refs, cross-namespace routes.
- `clusters/farm01/manifests/envoy-gateway-tls.yaml`: Certificate in farm01-edge using carverauto-issuer and DNS01 for the internal VIP.
- `clusters/farm01/manifests/cert-manager-issuer.yaml`: ACME account/credential references and scoped DNS solver.
- `clusters/farm01/scripts/41-external-dns-enable.sh`: service + gateway-httproute sources, explicit domain filters, external-dns-farm01 TXT owner, and upsert-only policy.
- `clusters/farm01/manifests/external-dns-rbac.yaml`: Gateway API reader permissions. The generic `k8s/external-dns` manifest has broader/older defaults; do not copy them over farm01's specific settings.

Add exact-host HTTP/HTTPS listeners for agentboard.farm01.carverauto.dev to the shared Gateway, with distinct section names (agentboard-http/agentboard-https). A dedicated cert-manager Certificate in farm01-edge requests only that hostname and produces agentboard-tls; the HTTPS listener references it in the same namespace. Extend the existing issuer with a solver scoped by exact dnsNames to that hostname, preserving existing solvers, ACME account, and secret refs. Keep app HTTPRoutes in this repo and point their sectionName at the new listeners; the HTTP route retains HTTPS redirect.

Enable hostname publication through the existing gateway-httproute external-dns source. Extend farm01's allowed domain scope for this hostname, preserving its TXT owner, upsert-only policy, existing filters, and referenced credentials. Verify the reconciled Gateway address yields the intended private address and no public proxying. Do not allocate a new public load balancer or hand-maintain DNS/TLS secrets.

Historical comments about revoked credentials are not evidence that today's credentials fail. Inspect controller/Certificate readiness during rollout without printing secret values; troubleshoot only observed failures. Verify Certificate Ready, Gateway listener readiness, HTTPRoute Accepted/ResolvedRefs, DNS resolution, HTTPS hostname/certificate, and HTTP redirect before claiming access works. Trusted-network restrictions must be verified before exposing a no-auth app.

### 10. Skills follow delivered commands

Write `skills/agentboard/SKILL.md` as the canonical workflow. Per-harness variants link/reuse it and contain only installation, environment/model, and hook differences for Claude, Codex, Pi, Grok, Cursor, OpenCode, OMP, Muse, and Herdr. Add shell-agent examples and a captain routing playbook. Do not invent or install unsupported hooks; optional deterministic heartbeat/renew wrappers are described only when usable.

Startup reads task state and unread inbox; active work explicitly renews the lease, checks ownership, and posts meaningful updates. Handoffs and links live on the board. Optional assistants use these same commands; board permission conventions do not supersede external authorization.

## Risks / Trade-offs

- [Spoofable declared API identities] → Restrict private-network exposure and document attribution as collaboration metadata rather than authentication; keep database credentials server-side.
- [Rate limits vary with replica count/shared Gateway IP] → Document per-replica limits, default to one replica, retain an agent bucket, and configure trusted-proxy handling explicitly before depending on forwarded client addresses.
- [HTTP write response is lost after commit] → Retry only pre-mutation 429 responses automatically; inspect durable records/history for uncertain write outcomes.
- [Expired workers can continue editing external files] → Explicit renew/recheck skills and visible expiry; no claim that the board fences external work.
- [Two language stacks and undeclared Elixir remote tools] → M1 includes remote toolchain/packaging setup and a real release smoke check before application rollout.
- [Notifications can be lost] → Snapshot-on-connect/reconnect plus five-second durable read fallback; do not market watches as event delivery guarantees.
- [Snapshot watches become expensive with large fleets] → Bound interactive reads, coalesce invalidations, and measure during M4; do not add a broker preemptively.
- [Quota reports carry uncertainty and account metadata] → Preserve source semantics/freshness, show only summarized evidence by default, and use synthetic fixtures.
- [Checked-in Gateway/issuer/DNS scopes omit the selected hostname] → Land the companion scoped GitOps change using existing cert-manager/external-dns and verify each controller's readiness before reporting access.
- [Storage/PG operator compatibility is environmental] → Preserve captain's pin, then verify remote integration and CNPG readiness during rollout; do not silently replace settled choices.

## Migration Plan

1. Build the M1 CLI/schema/dashboard release remotely and validate against an isolated TLS-enabled PostgreSQL instance. Use additive migration version 1.
2. Prepare the companion scoped GitOps listener/Certificate/issuer/external-dns change and matching app route section names. Before rollout, verify CNPG readiness, out-of-band secrets, worker API reachability/HTTPS trust, trusted-network boundary, and automated Gateway/DNS/certificate readiness. Do not print credentials or apply cluster changes from planning.
3. Publish the verified immutable image and CLI artifacts through the release workflow. Update overlay artifact references; let the existing Argo waves run schema migration before dashboard rollout.
4. Smoke registration, task creation, concurrent claims, an attributed update, JSON reads, health endpoints, and dashboard refresh. Record real remote and rollout evidence.
5. Deliver M2 additive migrations/triggers, matching CLI commands, subscriber, messages, stale labels, and atomic handoff; verify reconnect and expired recovery.
6. Deliver M3 additive quota schema, adapters/views, and skills; verify schema 5/6, uncertainty, repeated/out-of-order reports, and documented harness workflows.
7. Roll back a failed app rollout to the previous compatible image. Keep additive schema and board data; do not auto-run down migrations or delete history. If first deployment has no compatible previous app, stop traffic and fix forward while preserving the database.

## Open Questions

No product-contract decisions remain open for this draft. Exact toolchain versions, release workflow credentials, worker API addresses, and the external Gateway rollout owner can be filled in during their specific delivery tasks without changing these specs. Those environmental prerequisites must be satisfied before deployment is reported complete.

### Release command name

The captain selected `agentboard` for the Go CLI (2026-10-05), avoiding the existing ApacheBench `ab` command. Source and Bazel entry points are `cmd/agentboard`; platform assets are `agentboard-{linux,darwin}-{amd64,arm64}`. Install the selected remotely built asset at `~/.local/bin/agentboard`. Database notification topic names remain unchanged.
