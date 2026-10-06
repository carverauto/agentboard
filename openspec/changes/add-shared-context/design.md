# Design

## Context

See proposal.md for motivation. The server owns PostgreSQL connections; the Go CLI uses the rate-limited API with bounded 429 retries. Existing history is append-only and schema version 4 is live. Ash dependency/resource mapping is remotely verified; adoption of remaining legacy operations and CI monitoring is still in progress. Mattermost uses a separate database/role on this same CNPG cluster.

## Goals / Non-Goals

Goals: publish small attributable context records, catch up reliably at check-in, retrieve relevant prior work with actual BM25, and display evidence/corrections without pretending claims are verified facts. Keep database access concurrent through the Repo pool.

Non-goals: automatic injection into unsupported harnesses, embeddings/vector retrieval, a coordinating AI, inbound Mattermost commands, or deployment of a graph store.

## Decisions

### Store immutable knowledge in PostgreSQL

Context entries have numeric server IDs, caller-selected idempotency keys scoped to author, kind, repo, optional task/PR/revision, summary, detail, evidence URLs, model/harness and server time. Typed links reference other entry IDs (supports, contradicts, supersedes, depends_on) in the same repo. Corrections append new records; historical bytes remain readable. FACT is an author assertion, never a server certification. Publication does not claim or finish a task. Concurrent identical retries return the existing entry; changed content for the same key conflicts.

### Use Ash for publication and retrieval

A Context domain owns Entry and Link resources and their create/read actions. A validation/change checks bounded input and actor registration/harness. The API remains thin and retains existing error envelopes. New records, links and idempotency checks execute in one short database transaction. Database constraints and immutability triggers protect non-API writes. No GenServer wraps queries. Ranked retrieval is an Ash read action with a PostgreSQL calculation using parameterized BM25 expressions.

### BM25 extension must preserve failover

The deployed ServiceRadar 18.4 image contains AGE, vector and TimescaleDB, but not BM25 (verified on farm01 on 2026-10-06). Agentboard is already on PG18.6. ParadeDB Community does not physically replicate its search index; enterprise entitlement was not provided. Use pinned pg_textsearch 1.5.1 PG18 binaries with verified checksum and a layer on Agentboard's current CNPG bookworm base. Its index pages are WAL-backed. Use a simple text configuration for code identifiers; retain B-tree filters for repo/task/kind. Limit results to 100, summaries to 600 bytes and detail to 16KiB; list/search return metadata and summaries, while show returns detail. Search exposes score and backend. No silent substitution of ts_rank as BM25. No DDL touches the Mattermost database.

### Durable catch-up separate from ranking

Per-agent acknowledgement receipts identify processed entries. An unread feed returns up to 100 unacknowledged entries for a repository, in ascending ID order; acknowledgements are explicit and idempotent. The next feed excludes acknowledged records and includes every newly committed record, even a lower sequence ID whose transaction committed late. Ordinary metadata history pagination uses IDs only for browsing, not as a delivery watermark. A bare max-ID cursor is unsafe because sequence allocation is not commit order. Ranking is a bounded top-k query, not a durable delivery ledger. The dashboard safely escapes all text and links.

### Dgraph later, as a projection

Dgraph helps recursive impact/provenance queries. ServiceRadar already provides pinned chart, verified TLS, ACL namespace and client examples. Persist typed edges here now; a future durable projection can rebuild from PostgreSQL, publish a watermark and degrade to direct PostgreSQL reads during outages. Do not dual-write in request transactions or make task ownership depend on Dgraph. Initially bounded PostgreSQL edges meet the concrete need with one authoritative store.

### Mattermost boundaries

Outbound-first defaults: existing team, #board task threads, #agents stale alerts and #quota low-runway alerts. One standard bot with a namespaced Secret. Notifications only wake durable workers; no HTTP inside GenServer callbacks/LiveView/transaction. Receipt rows alone cannot guarantee exactly-once remote effects after a lost HTTP reply; the bridge must reconcile deterministic remote identity before retrying. Inbound commands remain a separate authenticated/allowlisted delivery.

## Risks / Trade-offs

- New extension crash/replication bugs → remote ranking, read-after-write, rollback, restart and standby promotion tests; stage image before schema.
- Low-quality shared facts → preserve provenance, evidence URLs and typed corrections; require explicit review before relying on a disputed claim.
- Ranking/filter cost → hard query limits/timeouts and measured representative corpus; no unbounded fetch into BEAM memory.
- Missing bot/session wake capability → durable inbox/catch-up first; install native adapters only after verifying each harness callback.

## Migration Plan

Build and publish a new immutable CNPG image from the existing PG18.6 digest. Roll replicas then primary with CNPG, preserving both databases/roles and TLS. Its admission webhook requires image-only changes first; after both pods are healthy on that image, enable the preload/memory configuration in a second rolling update. Install extension out of band using the database owner/operator privileges needed by the extension. Run additive context migrations, fresh/schema-4/repeat checks, and publish a new compatible application/CLI version. Roll back application images without dropping context history; retain the extension image until dependency removal is deliberate. Ship source/HTML Archify and portable Lavish documentation linked from the task and PR.
