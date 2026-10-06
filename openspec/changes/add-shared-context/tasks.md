# Tasks

## 1. Replicated BM25 database foundation

- [x] 1.1 Pin pg_textsearch 1.5.1 PG18 binary/checksum, package a CNPG layer on the existing PG18.6 base and document extension installation; verify remote image ABI/startup and ranking/restart/replica-promotion tests.
- [x] 1.2 Add immutable context entry/link tables and Ash resources/domain with bounded attributed idempotent publication; verify fresh/schema-4/repeat migrations, concurrent retries, changed-key conflicts and transaction rollback remotely; document schema/limits.

## 2. Agent and captain access

- [x] 2.1 Add Ash retrieval actions, API and Go CLI append/show/catch-up/search with explicit acknowledgement receipts and BM25 scores; verify remote real API/CLI ranking, filters, pagination, provenance and 429 compatibility; document commands.
- [ ] 2.2 Add escaped context dashboard and relationships plus shared skill check-in/publication guidance; verify desktop/mobile browser behavior and adversarial text safely rendered.

## 3. Reviewed delivery and rollout

- [x] 3.1 Deliver validated Archify source/HTML, portable Lavish proposal and PR/task links; run remote review/quality/CI gates before reporting ready.
- [x] 3.2 Roll out the immutable database/application releases preserving Mattermost's separate database/role and current Kanban/skills deliveries; verify live publish/search/catch-up, promotion behavior and retained history, recording evidence.

Production acceptance on 2026-10-06 is recorded in [verification](../../../docs/verification.md#shared-context-rollout-2026-10-06). Task 2.2 remains open until the evidence-link wrapping fix is merged, built and rolled; mobile search itself passed.
