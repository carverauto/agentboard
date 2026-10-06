# Proposal

## Why

Agents lose useful discoveries, repeat failed approaches and miss changes made by peers across sessions. Agentboard needs durable, searchable shared context alongside task ownership, with provenance and explicit corrections.

## What Changes

- Add immutable typed context entries (OBSERVED, FACT, FAIL, CLAIM, PATCH_SUMMARY), bounded summaries/details, evidence URLs, repository/task/PR/revision references and typed relationships.
- Expose append, show, incremental catch-up and ranked search through Ash domain actions, the Phoenix API and the API-only Go CLI.
- Add BM25 on the existing PostgreSQL 18.6 CNPG base using pinned pg_textsearch 1.5.1, after remote ranking/restart/replication checks. The deployed ServiceRadar image has no BM25 extension and uses PG18.4; reuse its build patterns without downgrading.
- Add a read-only context dashboard and check-in/publication guidance to shared agent skills.
- Preserve PostgreSQL as the authoritative store. Record Dgraph as a future rebuildable projection for multi-hop evidence/dependency traversal; no new Dgraph deployment in this delivery.
- Keep Mattermost integration separate: outbound notifications may link context entries; chat never owns context or task state.

## Capabilities

### New Capabilities

- `shared-context`: Durable attributed knowledge publication, corrections, catch-up and bounded BM25 retrieval across agents.

### Modified Capabilities

None. Existing task, message, quota and documentation contracts remain compatible.

## Impact

New Ash Context domain/resources, additive PostgreSQL tables/indexes, API routes, Go commands, context LiveView, agent skills and operator documentation. A custom CNPG extension layer preserves the current PG18.6 base and the separate Mattermost database/role. Builds and verification remain remote-only. Depends on the Ash dependency/resource foundation of adopt-ash-and-monitor-pr-ci; its remaining audit and CI work continues independently.
