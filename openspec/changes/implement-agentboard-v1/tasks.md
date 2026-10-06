# Tasks

## 1. M1 — Remote build and application foundation

- [x] 1.1 Add Go HTTP CLI dependencies and pinned Bazel dependency declarations without host compilation; verify a minimal configured CLI builds on BuildBuddy through `./scripts/bazel build //cmd/agentboard:agentboard`.
- [x] 1.2 Establish pinned remote OTP/Elixir and asset tool inputs plus a minimal Phoenix/API app under `web/`; verify a real application compile/release target on RBE, replacing the placeholder filegroup as the only web check.
- [x] 1.3 Provide an isolated remote PostgreSQL integration-test environment with TLS and deterministic cleanup; verify connectivity and that its DB is separate from farm01 and document the remote test recipe.

## 2. M1 — Shared schema and migration contract

- [x] 2.1 Add Ecto migrations for agents/tasks/task_events, schema version, indexes, state/foreign-key/attribution constraints, task revisions, and assignment metadata; verify fresh migration, repeat migration, and invalid state rejection against remote PostgreSQL.
- [x] 2.2 Implement migration release entrypoint and API schema compatibility checks and CLI error mapping; verify `Agentboard.Release.migrate()` works from the packaged release and incompatible CLI commands fail without automatic migration.
- [x] 2.3 Enforce append-only event history and implement database mutation helpers for transactional event creation; verify rejected update/delete and rollback when event insertion fails, and document schema ownership under `web/`.

## 3. M1 — Agent identity and CLI output

- [x] 3.1 Implement API URL/flag precedence, verified HTTPS trust, required actor/model/harness context, and structured HTTP/exit-code mapping; verify missing context, unknown actor, TLS failure, and direct malformed API calls leave state unchanged with stdout uncontaminated.
- [x] 3.2 Implement stable register/list/show, descriptive metadata/model refresh, and conflicting-harness rejection; verify re-registration preserves references and historical attribution remotely.
- [x] 3.3 Add stable JSON envelopes, UTC timestamps, null handling, deterministic ordering, and bounded keyset pagination; verify an actual non-interactive command can parse empty/populated/multipage results.
- [x] 3.4 Document API-only configuration, captain shell identity, registration, and JSON/error contracts in README/CLI help; verify the examples against remote-built `agentboard` without exposing credentials.

- [x] 3.5 Add versioned Phoenix resource/action API routes with validated provenance, bounded JSON parsing, shared context reads/mutation helpers, compatibility metadata, and structured status errors; verify CLI operations work with no database credentials and direct API calls enforce the same ownership constraints.
- [x] 3.6 Add a supervised configurable API rate-limit plug before parsing/mutations plus bounded watch reservations; verify 429/Retry-After/no-store, no mutation on throttling, expired bucket cleanup, disconnect capacity release, limiter failure, and unaffected health probes. Document per-replica and trusted-proxy behavior.
- [x] 3.7 Implement bounded cancellable client 429 retries with delay-seconds/HTTP-date, positive jitter/fallback backoff, replayable bodies, and deadline/error diagnostics; verify wait floors, eventual success, exhaustion, malformed/long delays, interruption, and no automatic replay of ambiguous non-429 writes.

- [x] 3.8 Review supervision and query paths against installed Elixir/OTP guidance: use plain contexts and pooled caller-process queries, with no query GenServer; verify an independent read/mutation completes while a different task mutation waits on a row lock, and notification/limiter lifecycle processes do not serialize database work.

## 4. M1 — Task records, ownership, and timeline

- [x] 4.1 Implement task create/list/show/edit/link with explicit or generated slugs, validated metadata/URLs, filters, and attributed events; verify duplicate IDs, unchanged history after model changes, and task/event transaction rollback.
- [x] 4.2 Implement atomic assign/claim acceptance and actor/state guards through database mutation functions; verify two concurrent claimers produce one success, assigned-agent acceptance succeeds, and another agent cannot steal assigned work.
- [x] 4.3 Implement two-hour/default-configured leases, explicit renew/release/reclaim, and database-time expiry; verify expiry does not auto-release, heartbeat-independent renewal, boundary races, and stale-owner write refusal.
- [x] 4.4 Implement reasoned note/status updates and the specified lifecycle, including terminal immutability and cancellation; verify invalid transitions, blocked reasons, owner-only active edits, and terminal lease cleanup.
- [x] 4.5 Document task lifecycle, lease recovery, cancellation instead of deletion, and the scope of logical ownership; verify the documented create/assign/claim/update/release flow against remote PostgreSQL.

## 5. M1 — Read-only dashboard

- [x] 5.1 Add Ecto board reads, status-column board, and task detail with attributed/paginated history and safe GitHub links; verify LiveView reads reflect CLI writes and task content is escaped.
- [x] 5.2 Add five-second mounted-view refresh, distinct empty/unavailable/stale states, and initial registry views; verify a CLI mutation becomes visible within five seconds and a failed DB read is not shown as an empty healthy board.
- [x] 5.3 Implement process liveness and DB/schema readiness at the existing probe paths; verify DB outage fails readiness while process liveness stays healthy.
- [x] 5.4 Update web/README and root README with the delivered read-only surfaces and pre-alpha limitations; verify each documented route and M1 acceptance criterion using the remotely packaged app.

## 6. M1 — Packaging and cluster integration

- [x] 6.1 Build Linux/Darwin amd64/arm64 CLI binaries with checksums remotely; verify package metadata/checksums and execute Linux artifacts remotely, recording any platform runtime verification not available.
- [x] 6.2 Package the dashboard release as a nonroot/read-only-compatible Harbor image with temporary state under /tmp; verify release startup, migration entrypoint, assets, and probes remotely.
- [x] 6.3 Wire split DB variables/DATABASE_URL precedence, trusted CA mounts, immutable shared app/migration artifact references, and existing Argo waves; verify rendered farm01 YAML preserves the confirmed CNPG/storage/image/host decisions and contains only secret references.
- [x] 6.4 Prepare a companion GitOps PR for exact-host agentboard HTTP/HTTPS listeners, cert-manager Certificate/DNS01 solver scope, and farm01 external-dns domain scope/source/RBAC; verify manifest rendering preserves existing solvers/listeners, TXT owner, upsert-only policy, and unrelated DNS filters.
- [x] 6.5 Point app-owned HTTPRoutes at the new listener section names and document automated certificate/DNS, CLI private API connectivity/HTTPS trust, and rollout/rollback prerequisites; verify the app and companion GitOps manifests agree on hostname, listener names, TLS secret, and Gateway references.
- [x] 6.6 Replace placeholder-only BuildBuddy validation with M1 remote targets and wire artifact publication automation; verify the pipeline builds/tests/packages real outputs without local compilation or warning-as-error flags.
- [ ] 6.7 After release/operator rollout authorization, verify isolated M1 end-to-end behavior and farm01 prerequisites: CNPG/migration readiness, Certificate Ready, Gateway listener status, HTTPRoute Accepted/ResolvedRefs, private DNS, HTTPS certificate, redirect, and board/CLI smoke flow; record actual evidence and keep deployment incomplete if any prerequisite fails.

## 7. M2 — Heartbeats and stale work

- [x] 7.1 Implement busy/idle heartbeats, owned-current-task validation, server timestamps, and current model/backend metadata; verify heartbeat does not extend leases and rejects unknown/unowned current tasks.
- [x] 7.2 Add ten-minute/default-configured liveness and separate expired-claim flags to CLI reads, roster, cards, and details; verify flags advance with time and a fresh agent can still hold an expired claim.
- [x] 7.3 Document heartbeat/renew responsibilities and explicit stale recovery commands; verify a stopped worker remains visible and a recovery actor can deliberately release/reclaim its expired work.

## 8. M2 — Durable messages and handoffs

- [x] 8.1 Add messages migration, destination constraints, sender/read provenance, and inbox/task indexes; verify unknown recipients/tasks and empty destinations are rejected remotely.
- [x] 8.2 Implement message send/list/read with task comments, caller inbox, unread/task filters, pagination, and JSON; verify listing has no acknowledgement side effect and only the recipient can idempotently mark a direct message read.
- [x] 8.3 Implement atomic live-owner handoff to assigned plus reasoned event and recipient message; verify message failure rolls back the whole handoff and the new assignee must claim.
- [x] 8.4 Add dashboard message feed/task thread and document inbox versus shared task-thread semantics; verify filters and that read-only dashboard views do not mark messages read.

## 9. M2 — Live subscriptions

- [x] 9.1 Add topic notification triggers with compact payloads and commit-only behavior; verify subscribers observe successful commits and receive nothing for rolled-back mutations.
- [x] 9.2 Add one supervised Phoenix database listener and PubSub invalidation/requery with burst coalescing and fallback refresh; verify listener restart/disconnect recovery and five-second visibility when notification delivery fails.
- [x] 9.3 Implement Phoenix HTTP snapshot streams plus task/message CLI watches and list --watch aliases with initial complete filtered snapshots, NDJSON, consistent multipage reads, reconnect reload, bounded backoff including 429/Retry-After, watch-capacity cleanup, and signal cancellation; verify startup races, missed notifications, disconnected writes, and termination.
- [x] 9.4 Document snapshot rather than durable-event-stream semantics and available filters; verify the remote M2 workflow covers heartbeat, handoff, unread acknowledgement, and watcher/dashboard recovery.

## 10. M3 — Quota storage and adapters

- [x] 10.1 Add quota_reports and provider/account/window/scope projection migrations, source attribution, raw JSON, generation/ingestion times, and canonical-digest idempotence; verify transaction rollback and exact retry handling remotely.
- [x] 10.2 Implement stdin/file schema 5/6 ingestion using synthetic producer-contract fixtures; verify schema 5 default account, schema 6 multiple accounts, unsupported/duplicate/malformed rejection, and preservation of raw/optional fields.
- [x] 10.3 Project producer windows/scope semantics without inventing capacity, reset clocks, or runway; verify parent-share, unknown/conflicting/untrusted availability, through_reset, stale/unavailable state, and advisory spend priority.
- [x] 10.4 Implement latest whole-observation selection and quota list filters/JSON/pagination; verify older arrivals do not supersede newer reports and newer empty-window reports remove prior windows from latest reads.
- [x] 10.5 Add ab_quota notifications and quota watch/list --watch using the M2 subscription contract; verify push visibility and reconnect recovery.
- [x] 10.6 Document the quota producer pipe, supported versions, account identity, raw history, idempotence, and freshness semantics; verify the synthetic schema 5/6 CLI examples and confirm no provider credential refresh occurs in agentboard.

## 11. M3 — Quota dashboard and agent skills

- [x] 11.1 Add provider/account/window/scope quota panel with remaining/reset/runway/selection/freshness and unknown/error states; verify multi-account display, exhausted highlighting, and absence of automatic assignment or dispatch.
- [x] 11.2 Create canonical skills/agentboard/SKILL.md for durable startup reads, ownership verification, explicit renewal, updates, messages, handoff, and links; verify every referenced command exists and run its workflow with two remote test agents.
- [x] 11.3 Add thin variants for Claude, Codex, Pi, Grok, Cursor, OpenCode, OMP, Muse, and Herdr-hosted sessions plus plain shell examples; verify shared command consistency and harness versus backend tags without unsupported hook claims.
- [x] 11.4 Add captain/assistant quota-routing playbook and installation guidance; verify it presents explicit assignment choices and does not imply board ownership authorizes external deployments or merges.

## 12. M1–M3 integration acceptance

- [x] 12.1 Run the full remote acceptance scenario with two harness identities: concurrent claim conflict, model-stamped progress, explicit renew/expiry/reclaim, live dashboard/watch recovery, atomic handoff, message acknowledgement, and schema 5/6 quota visibility; verify API-only access, rate-limit protection, and client retry/cancellation; record BuildBuddy results and any unavailable checks as untested.
- [x] 12.2 Verify the release artifacts, additive migrations, matching deployment image, automated DNS/cert prerequisites, and documented rollback together; confirm the README's implemented/deferred status matches delivered behavior and remains pre-alpha.
