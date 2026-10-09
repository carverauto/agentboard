# Captain repository pins verification

## Scope and dependency

This is the second bounded implementation increment for #185, following the
explicit 2026-10-09 approval of the complete three-phase design. It adds captain
pin configuration and display ordering only. Integration roles/intake, provider
metadata, topology, mini-trees, risk ranking and numeric divergence remain open.
Presentation stays off by default; no deployment or live flag change is included.

The implementation starts from exact PR #200 head
`17e6fbe45535a0afed69afa22db1ed3ff9aa1660`. Fresh main was
`c723301053d0f2d7fd3d678866e8b378c25cf434`, which did not yet contain that head.
After PR #200 merged, the parent coordinated a fresh fetch and clean rebase onto
`8bae8da2e6ade9e3d0829a431524b7b6be786d9d`. That main tree exactly matches the
original dependency head; pin changes were preserved. This task did not merge or
replace PR #200. Final checks were repeated after that rebase.

Read-only migration/task/message inventory found no competing logical37 /
physical `20261008003700` allocation. This is a proposed code allocation under
`codex-agentboard-dot-coordinator`, not an atomic board reservation. Recheck
then-current main and open changes before publication; stop on a collision.

## Delivered boundaries

- Audited singleton display configuration with at most five exact canonical,
  unique, ordered repository paths. Strict full-replacement validation rejects
  unknown fields, unavailable pins and malformed identities. No defaults are
  materialized by a read.
- A dedicated transaction lock serializes initial creation and subsequent CAS.
  Server-held captain capability is rechecked after lock acquisition, immediately
  before writes, and before commit. Expiry/rotation during a later database wait
  rolls back configuration, audit, version history and receipt together.
- Immutable exact-request receipts distinguish an original committed revision
  from newer current configuration. Changed payloads cannot reuse a key. An
  uncertain outcome requires read-only reconciliation before an exact-key retry.
- A bounded twenty-row Settings chooser shares eligibility SQL with the strip.
  It never calls the full PR/attention projection or fetches provider evidence.
  Canonical validation is aligned across legacy inventory, service and database
  guards; queued/ignored cues and disabled nonterminal records are not eligible.
- Eligible pins lead the five-card order, then busiest unpinned repositories.
  Missing pins remain stored and visible for explicit repair. Held order, global
  oldest-red attention, table filters and independent paging remain unchanged.
  Configuration and inventory share a read-only repeatable-read snapshot.
- Explicit checkbox/order/Save/Reload/Close controls keep actor, expected revision
  and idempotency key server-side. Dirty discard is explicit. Same-session
  uncertain close/reopen retains and reconciles the original submitted request.
  No client event can autosave or opt into the presentation rollout.

## Executable verification

All runtime records, tokens, certificates, endpoints and repositories used here
are invented fixtures in the disposable Linux VM. PostgreSQL uses verified TLS;
application tests use a nonsuperuser/non-CREATEDB/non-CREATEROLE/non-BYPASSRLS role.
The VM exception does not permit local maintainer-workstation builds. Every Bazel
invocation uses the repository remote-config wrapper.

On the rebased source:

- Full ExUnit: **164 tests, zero failures**. This includes five settings validation
  tests and twenty-three editor state-machine/render tests, as well as existing
  frontend-auth, settings, fleet, projection and delivery unit coverage.
- Production test/prod compilation, pinned Tailwind/esbuild asset generation and
  packaged release creation passed. All **242 source/build input files** compared
  byte-for-byte, including lib/config/migrations/assets/tests and Mix manifests.
- Go `test ./...`, `test -race ./...` and `vet ./...` passed.
- Eight Node VM tests of the production pin-editor hook passed, including an
  older clean search response after a local pin click, multiple overlapping reset
  responses, newer edits after Save/Reload, disabled inputs, Escape/focus cleanup
  and modeled back-forward-cache return. Existing details/dialog hook tests passed.
- The complete new `branch_flow_settings_test.py` passed against a fresh
  normal-role PostgreSQL and the packaged release. It exercises concurrent first
  saves/CAS, exact-key replay and changed-request conflict, expiry/rotation while
  waiting on the configuration lock, inventory read and final receipt insertion,
  forced receipt failure with full configuration/history/audit rollback, immutable
  update/delete/truncate protection, read-only uncertain outcome reconciliation,
  and old committed receipts versus newer saved revisions.
- That same suite verifies exact canonical inventory, twenty-row chooser,
  pin-first fill and five-card cap, stale-pin storage/repair, same-snapshot
  settings and inventory during a concurrent save, settings-only degradation
  preserving twenty PR rows plus ten attention runs/global oldest, and
  pins-plus-alphabetical fallback when aggregates fail.
- Real signed-session LiveView coverage includes search/paging selections,
  ordered moves, repeated selection/save, forged actor/revision/key rejection,
  dirty Close/Reload confirmations, stale draft retention, lost committed/no-
  commit responses, explicit read-only reconciliation/exact retry, failed loads,
  unavailable-pin repair, reconnect and captain rotation. Provider spies observe
  no requests; complete operational table/worker-job/agent-row fingerprints stay
  unchanged by settings and view exploration.
- The release-schema suite passed upgrades from older actual migration sets,
  including schema36 and marker99, repeat migrations, empty settings/history/
  receipts immediately after upgrade, unchanged operational rows, populated
  immutable evidence retention and invalid shape guards. The VM wrapper changes
  only fixture transport to certificate-verified TCP (Unix sockets are prohibited).

Existing packaged regressions passed for FleetLoadout Settings, default-branch
workflow intake/recovery, conflict/base-watch accountability, CI accountability
and shadow coordinator triage. Conflict tests use their required observation
flag and a UTC fixture; the triage and pins suites also exercise a Chicago
PostgreSQL session. A separate non-UTC diagnostic exposed an existing
poll-state/snapshot timestamp mismatch in unchanged producer code; it is not
fixed or hidden by this display-only slice. Direct pin create/update probes in a
Chicago session retained the actual UTC write instant, and the new suite asserts
that the final persisted pin timestamp remains within the real write window.

The final large Branch Flow regression passed with 1,000 additional repositories
and 10,000 additional PRs. All query plans executed; application result counts
stay capped at five cards/fifteen relations/twenty chooser rows/twenty table rows
and ten attention runs plus the persistent oldest. Rich twenty-row projection
parity reported zero differences. Provider/job/operational mutation checks and
LiveView route, refresh, rejoin, independent cursors and degraded reads passed.
Measured refresh cost was **70–84 SQL calls, 156 returned SQL rows and 26.1–79.9ms**
for the recorded small/large fixtures. The legacy list used 167 calls and
68.9–71.9ms; these snapshots are measurements, not production-load guarantees.

An earlier mixed-inventory query plan underestimated canonical tracked rows and
rescanned 10,069 rows for each of 1,028 repositories. The final shared inventory
aggregates tracked counts per repository before joining eligible identities,
removing that all-PR/all-repository join. Exact eligibility, terminal/unknown
counts, pin order and chooser parity are retained. The independent reviewer
approved that structural cost correction, and the full pins/large-fixture suites
were rerun.

## Independent review

The independent read-only review caught a 256-byte repository editor boundary
mismatch and a delayed-search dirty-navigation race. The editor now matches the
shared identity bound; local unacknowledged edit custody survives unrelated clean
server patches. A Node VM regression exercises the actual production hook with
controlled event ordering. It is not a real browser test.

Real database fault injection also found that optional Ash read failures could
abort the entire read transaction despite the section savepoint. The singleton
settings read now uses one parameterized PK lookup. Attention uses the same
bounded resource-schema fields/filter/order via Ecto; WorkflowRun has no read
policies/preparations being bypassed. All mutations remain audited Ash actions.
The full suite and separate fault probes verify independent section degradation.
The independent reviewer approved both read-path deltas.

The navigation guard is deliberately conservative: manually reverting an edit
may retain an unload prompt until an explicit confirmed Save/Reload/Close. It
never treats an unrelated clean patch as proof that pending local input settled.

## Limits

- Remote Bazel was attempted through `scripts/bazel`, which stopped because
  `.bazelrc.remote`/BuildBuddy credentials are absent. No local Bazel fallback or
  credential change was attempted; aggregate remote acceptance is unrun.
- Installed Chromium could not open even an empty headless page: its process
  singleton socket is prohibited (`Operation not permitted`). No restriction
  bypass was attempted. Actual keyboard, focus, native unload prompts,
  Back/Forward cache, screen-reader, 320px/mobile, 200% zoom, themes and perceptual
  acceptance remain unrun. Node hook and LiveView protocol/render tests are
  separate evidence, not replacements for those checks.
- Single-host large synthetic data and transaction races are not concurrent
  production-load acceptance. No provider repository-ID/rename feed exists;
  tests establish exact local identity retention, not live rename detection.
- Required remote publication/fresh-base checks, hosted current-head CI, strict
  OpenSpec CLI, Archify/Lavish output and operational rollout remain separate.
  No board writes, worker contact, credentials, push, merge or deployment were
  performed in this implementation task. #185 remains open.
