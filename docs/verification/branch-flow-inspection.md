# Observed PR relationship inspection verification

## Scope and exact base

This read-only #185 slice builds on the exact approved pin branch
`f9ff509e61dff2f2be743ba105f4b2090652407f` while PR #202 is open. It adds a
focused twenty-relation repository page, exact-endpoint schematic with an always
visible text alternative, one non-modal selected-PR inspection, and matching
four-column-table glyph/disclosure. The implementation is prepared as a local commit stacked on that pin head;
publication, retargeting and current-head CI are separate verification steps. No merge of #202
is assumed. Any later rebase must repeat applicable final checks.

The user explicitly approved continuing the complete #185 design and permits an
isolated worktree in this disposable VM. Implementation does not use the primary
checkout, a maintainer workstation or a Codex Cloud executor. No migration,
provider call, producer/effect-admission change, board write, worker contact,
credential change, push, merge, deployment or live flag activation is included.
The preview remains off by default. Existing pin/CAS resources are unchanged.

## Evidence contract and bounds

One shared exact-source binding qualifies overview, topology, table glyph and
inspection: canonical PR, snapshot ID, head/base SHA, observed time, generation
and exact base ref must agree. Existing `Reads`/`BaseMonitor` expected-base
qualification remains authoritative, including watch advance before paged poll
invalidation. Retained failing CI/repairs stay visible while unproven success and
freshness are removed. A total read failure also de-qualifies last-known relations
on every retained surface.

Topology uses twenty open PRs plus a query sentinel. Compact snapshot reads omit
historical/full attempt payloads. Exact repository/ref/SHA triples alone dedupe
endpoints, with at most forty endpoints/twenty connectors. Missing identities,
multiple observed SHAs for one ref and cycles fall back to listed relations.
A nonrecursive exact-parent lookup uses a two-match ambiguity sentinel. Selected
inspection reuses a table record when present, otherwise loads one bounded record;
source attribution and failure summaries each use ten entries plus a sentinel.
Full history remains an ordinary full-detail link.

Default branch, integration role/health, title and numeric divergence are not
invented. There are no ancestry/return/promotion edges or inferred current tips.
Independent topology cursors bind repository/node selection, while table search
and terminal filtering keep their own scope. Route, selected PR and monotonically
increasing client/dismissal generations fence interaction. Reads stay synchronous
and read-only in a repeatable-read transaction with the existing two-second
statement timeout. No rendering path schedules provider work or changes business
state.

## Completed checks

- 179 ExUnit tests passed, including the full initial PR render with no selection,
  malformed repository-map rejection, exact-source binding matrix, independent
  topology cursors, missing/ambiguous/cyclic endpoint handling, forty-endpoint /
  twenty-connector ceiling, and non-modal inspection responsibility/provenance.
- Ten production-hook ordering tests passed: normal open/refresh, A→B replacement,
  close before open response, explicit close/toggle, outside target focus,
  navigation, Back/Forward/cache return, removal fallback and glyph hiding.
  Same-route/hash/modified/new-tab navigation does not latch suppression.
  The eight existing pin-editor hook tests also passed.
- Go tests, race tests and vet passed. Production compilation, Tailwind CSS,
  JavaScript bundle and OTP release passed. All 251 source build/test inputs match
  the final isolated build workspace; generated release assets are built from
  those inputs. Existing compiler warnings were not promoted to errors.
- `branch_flow_inspection_test.py` passed against fresh certificate-verified TLS
  PostgreSQL with a normal application role and the real production release.
  Fixtures include 48 open relationships in one repository, retained terminal
  records, fork refs, a unique off-page match and mixed on/off-page duplicate
  matches. Source attribution and failed-attempt lists each exceed ten entries.
- That suite passes exact PR/snapshot/head/base/time/generation/ref and nil-source
  mismatch tests, authoritative base-watch advance before poll invalidation,
  head replacement/recovery, age expiry, unknown policy/null mergeability,
  independent attention/table/topology/chooser navigation, route/client generation
  rejection, one popover/drawer, source truncation, malformed route handling,
  graph/glyph hiding, close-before-response model, rejoin, and removal/read-failure
  invalidation. The normal schema prevents dangling snapshot foreign keys;
  missing-source fallback is additionally covered by the pure guard path, without
  disabling database integrity.
- View interactions produced zero provider requests and no changes in complete
  business/evidence fingerprints, including poll state, obligations, workers,
  jobs, source/snapshot/base-watch records, pin settings/history/receipts and
  board-action audit. Fixture setup changes are isolated invented data only.
- Existing overview regression passes with unchanged 85-query ceiling and exact
  rich twenty-row parity (zero differences), including duplicate/worker/decision/
  delivery context. Existing captain pin/CAS/expiry/rotation/rollback/receipt and
  interrupted LiveView save flows pass on the optimized release.
- Existing FleetLoadout settings, shadow coordinator triage, CI accountability,
  default-branch workflow intake/recovery and conflict/base-watch regressions pass. Conflict/workflow fixtures use their
  required observation flag and UTC; no production flag is activated. This slice
  does not alter the previously documented non-UTC producer timestamp mismatch.
- Independent review found and fixed same-route suppression, stale positive
  topology labels after whole-read failure, mixed on/off-page parent ambiguity,
  and unsafe interpolation of a rejected map-valued repository. Initial real
  rendering also caught nullable boolean guards; the full-render test now covers
  the empty selection. Final review checks the exact committed diff.
- Whitespace and local documentation-link checks passed. No migration or live
  schema reservation is needed; the pin branch's existing schema 37 is unchanged.

## Query, cardinality and timing evidence

The preexisting overview benchmark is still below its original 85-command budget:
59 commands / 181 returned SQL rows / 31.3ms on its small fixture; 73 / 181 /
84.2ms after adding 1,000 repositories and 10,000 PRs. The corresponding legacy
list makes 167 commands. No budget assertion was loosened. Shared branch-flow
freshness now uses the transaction's captured `as_of`, removing redundant
per-relation clock SELECTs while leaving ordinary API/detail freshness unchanged.

The new suite independently captures all query events and runs
`EXPLAIN (ANALYZE, BUFFERS)` for every distinct read. All plans executed successfully.
Large-fixture full projection samples, after adding 1,000 repositories / 10,000 PRs:

| View | SQL commands | Returned SQL rows | End-to-end sample |
| --- | ---: | ---: | ---: |
| Overview | 74 | 178 | 92.7ms |
| Focused twenty-relation page | 74 | 265 | 147.2ms |
| Selected topology inspection | 96 | 126 | 121.2ms |
| Selected table drawer | 84 | 118 | 117.8ms |

These are different selections, so subtracting full-view totals would not isolate
feature cost. Exact inclusive savepoint spans establish the new sections:

| New section | SQL commands | Returned SQL rows | Summed database sample |
| --- | ---: | ---: | ---: |
| Twenty-relation topology | 16 | 86 | 41.6ms |
| Selected topology inspection | 20 | 30 | 4.05ms |
| Selected table inspection (reuses row) | 8 | 22 | 1.85ms |

Counts include savepoint/release commands and nested subreads. Each failure or
submission-source subread uses three commands and returns eleven sentinel rows,
exposing at most ten records. Application limits remain five cards / fifteen card
relations / twenty table rows / twenty topology relations / twenty chooser rows /
ten attention runs plus oldest summary / one selected inspection. Small and large
fixtures retain the same section result bounds. No source records or full attempt
history are hydrated for every graph node.

These are measured single-host samples, not P95 or production-load claims. Full
JSON query/plan summaries and rendered protocol HTML remain local verification
artifacts; no external board upload or public document was created.

## Explicitly separate, unrun acceptance

- `./scripts/bazel test //web:branch_inspection_live_test
  //build/integration:branch_flow_inspection_test` stopped before execution because
  `.bazelrc.remote` and BuildBuddy configuration are unavailable. No local Bazel
  fallback or credential access was attempted.
- Actual browser keyboard, focus, screen-reader semantics, 320/768/1440 widths,
  200% zoom, light/dark, reduced motion, perceptual screenshots and browser
  disconnect/reconnect/history acceptance are unrun. The known Chromium AF_UNIX
  process-singleton restriction is unchanged; Node hook models and LiveView
  protocol/render output are not substitutes for browser proof.
- Ten concurrent five-second refresh clients, production-load P95 below one
  second, and no statement over two seconds remain a separate rollout gate.
  Single-host fixture samples are not production-load guarantees.
- Strict OpenSpec, Archify and Lavish tools are unavailable. No tool-authored
  diagram/export or durable task-document upload is claimed.
- Role metadata/intake, integration health, numeric producer acceptance, card
  risk ranking and separate rollout authorization remain unfinished. This slice
  does not close #185.
