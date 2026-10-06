# Proposal

## Why

Firstmate's central AI coordinator drifts and spends tokens reconciling task state spread across chat and files. Agentboard needs a durable shared board that agents update directly and the human captain can inspect, using the foundation already committed to this repo.

## What Changes

- Implement the full M1–M3 scope from [PRD #1](https://github.com/carverauto/agentboard/issues/1), delivered in three independently verifiable stages: core board; live updates and messaging; quota and skills.
- Replace the `agentboard` stub with an HTTP API-backed Go CLI for registration, heartbeats, task creation/editing, assignment, atomic claim, explicit lease renewal, release, handoff, links, messages, watches, and quota ingestion. Provide stable JSON for non-interactive callers.
- Persist agent identities, current task state, append-only provenance-bearing events, messages, and quota reports in the dedicated CNPG database. Use caller-chosen stable slugs and two-hour claim leases; expiry requires deliberate release/reclaim and never silently reallocates work.
- Host a versioned JSON API in the Phoenix application as the sole CLI transport; only Phoenix connects to PostgreSQL. Apply configurable API rate limits before mutations and return 429 with Retry-After; the CLI uses bounded, cancellable retries that respect the advertised delay.
- Build a Phoenix/Ecto/LiveView captain dashboard with board, roster, timeline, message feed, and quota panel. M1 is read-only with a documented refresh interval of at most five seconds; M2 adds database notifications and stale ownership visibility.
- Ingest quota-axi schema 5/6 reports while preserving provider/account/window/scope distinctions, source freshness, uncertainty, and raw report data. Supply evidence for human routing without automated dispatch.
- Publish shared and per-harness workflow skills, remote-built CLI binaries, and a Phoenix release image compatible with the existing farm01 migration, probes, and deployment manifests.
- Preserve confirmed infrastructure choices from issue comments: Bazel/BuildBuddy only, namespace/database `agentboard`, dedicated `agentboard-db`, `local-path-cnpg`, pinned PostgreSQL 18 image, Harbor images, and the in-repo route for `agentboard.farm01.carverauto.dev`. Plan a companion GitOps change using existing cert-manager DNS01 and external-dns Gateway patterns to supply matching listeners, certificate, and DNS publication.

Out of scope: authentication, multi-tenancy, NATS/JetStream, an AI coordinator or auto-dispatcher, harness spawning/worktree orchestration, GitHub mutation/synchronization, Firstmate data import, retention deletion, and M4 operational hardening. All v1 access stays on the trusted internal network.

## Capabilities

### New Capabilities

- `agent-registry`: Stable agent identity, stamped write context, heartbeats, and computed liveness.
- `task-board`: Durable task lifecycle, atomic ownership/leases, GitHub links, and append-only history.
- `board-messaging`: Durable direct messages and task comments with recipient read state.
- `board-live-updates`: Server-side PostgreSQL change notifications and recoverable HTTP CLI/dashboard subscriptions.
- `captain-dashboard`: Read-only board, roster, task timeline, messages, and quota views.
- `quota-visibility`: Schema 5/6 quota ingestion, history, freshness, and account/scope-aware summaries.
- `agent-workflows`: Shared and harness-specific instructions for board-based collaboration.
- `board-delivery`: Versioned HTTP API, rate limiting/client backoff, remote build/test packaging, releases, migrations, and trusted-internal farm01 deployment.

### Modified Capabilities

None. The main OpenSpec spec inventory is empty.

## Impact

- Implement `cmd/agentboard` and new focused Go packages; use Go net/http for API transport and CLI argument handling with pinned Bazel dependencies; distribute no PostgreSQL driver or database credentials to agents.
- Create the Phoenix application, Ecto migrations, API controllers/contexts, rate-limit plug, read models, notification subscriber, assets, and release entrypoint under `web/`.
- Extend `MODULE.bazel`, Bazel targets, remote toolchains/platforms, and `buildbuddy.yaml` beyond their current placeholder checks; add packaging/release automation and `skills/` documentation.
- Adapt existing `k8s/` manifests for real image digests, runtime database TLS configuration, migration ordering, and probes. Coordinate a separate GitOps change for cert-manager, shared Gateway listeners, and external-dns hostname scope, following inspected farm01 conventions. No deployment or GitOps source edit is performed by this proposal.
- Adopt the PRD as product intent, its later captain comments as settled infrastructure decisions, the user's selected ownership policy as the v1 lease contract, and the user's API-only correction as the transport contract even where the original README/PRD suggests direct database access. Model/harness are required for new attributed writes despite nullable fields in the PRD's illustrative schema.
