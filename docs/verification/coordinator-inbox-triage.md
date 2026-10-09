# #186 first slice: classification, audit and read visibility

## Scope and migration custody

Implementation base: `a46cca5` (includes the merged #195 triage design and #196
branch-flow design; this slice does not implement #185).

Code allocation: logical schema **36**, migration **20261008003600**, owner
`codex-agentboard-dot-coordinator`, issue **#186**, scoped to dormant off/shadow
configuration and immutable coordinator Message-ID classification/history.
Read-only main/open-PR/scoped-context inventory was checked at 2026-10-09 20:52
UTC: main ended at 35, no open PR or 36+ reservation was found. This is a proposed
code allocation, not an atomic board reservation. No board mutation was authorized
or performed. Existing #169 allocation 32 / 20261008003200 remains reserved and
must not be reclaimed. Recheck current main/PR custody immediately before
publication and reconcile any collision rather than overwriting it.

The migration uses `GREATEST(version,36)`, retains lower/future migrations,
creates no configuration/source/triage records, and refuses rollback that would
discard history. Upgrade tests cover fresh databases, existing historical schema
paths, schema35 twice and higher marker99 preservation.

## Implemented boundary

- Strict v1 explicit input, six-way normalization, canonical Message-ID dedup.
- Immutable source claims, initial append-only disposition and transactional audit.
- Captain-only audited configuration CAS, default off and shadow only.
- Exact non-consuming API/CLI reads, filter-bound lists and Messages dashboard.
- Unverified source claims visibly blocked; no CI selector, assignment, currentness,
  channel suppression, delivery, read/handled receipt or native consumer changes.

#153 signed delivery remains unavailable; #122 producer linkage, #156 wake/channel
fencing and #169 currentness stay with their existing owners. No live mode change,
webhook, credential, worker enrollment, deployment, scheduler or sweep retirement
is part of this code approval.

## Verification

Checks, review and limitations for the settled source are recorded below. The assistant VM toolchain is distinct from a
maintainer workstation. All Bazel checks use remote configuration; unavailable
BuildBuddy credentials are a blocker, not permission for local Bazel fallback.

### Passed on the final implementation source

Commands below source the verified assistant-VM `toolchains/env.sh`; no test used
production credentials or services. The final commit and tree identifiers are
reported with the local handoff rather than embedded in their own commit.

- `go test ./...`, `go test -race ./...`, `go vet ./...`: passed.
  Logs: `triage-go-tests.log`, `triage-go-race.log`, `triage-go-vet.log`.
- CLI fixture binary: `go build -buildvcs=false -o .../agentboard-triage ./cmd/agentboard`.
  Default VCS stamping failed to obtain repository status in this environment;
  disabled stamping is confined to the local test binary.
- All ExUnit via `MIX_ENV=test mix test --no-start`: **120 tests, zero failures**.
  Log: `triage-final-exunit.log`. Affected Elixir formatting, Python syntax,
  shell syntax and Git whitespace checks passed.
- Production `MIX_ENV=prod mix compile`, pinned Tailwind/esbuild assets, and
  `MIX_ENV=prod mix release --overwrite`: passed. Logs: `triage-prod-compile.log`,
  `triage-assets.log`, `triage-release.log`, `triage-admission-compile.log`.
- Packaged `coordinator_triage_api_test.py` through the real release, CLI and
  certificate-verified PostgreSQL with `FIXTURE_NORMAL_ROLE=true`,
  `TZ=America/Chicago`: passed. Log: `triage-api.log`.
  - Exact metadata/types/codepoint bounds and legacy inputs, all classes,
    canonical scope and untrusted producer claims.
  - Captain-only configuration, CAS, enforced coordinator own-inbox reads,
    forged attribution/provenance refusals.
  - Source/record/disposition/both action-audit rollback, immutable storage,
    concurrent capture/replay and conflicting retries.
  - Deterministic before-insert gate proves concurrent shadow configuration
    replacement waits for source capture; old/new messages retain their exact
    respective revisions.
  - Complete filter-bound pagination in a non-UTC database, late lower-ID commit
    discovery, configuration rotation and no inferred source acknowledgment.
  - Real rendered LiveView joins and repeated URL patches prove selector state,
    unresolved messages, raw/unread reset, truthful shadow badges, and unchanged
    receipt/audit/operational state during reads.
- Exact-final normal-role packaged regression suites passed:
  `cooperation_api_test.py`, `wake_intents_test.py`, `decision_requests_test.py`,
  `availability_api_test.py`, `seat_scope_api_test.py`, `fleet_loadout_api_test.py`.
  Logs: `triage-final-<suite>.log`. The broad existing `board_api_test.py` also
  passes with `TZ=UTC` and the normal role (`triage-final-board-api-utc.log`),
  covering ownership, lifecycle, messages/handoff, commits, streams, quota,
  documents, expiry, nonqueued checkout and LiveView outage behavior.
  Wake coverage includes actual 120-second
  uncertainty retention and the existing source/worker lock-order regression.
- Full `release_schema_test.sh` content ran through the TCP-only VM fixture
  adapter, with only archive extraction/socket bootstrap replaced. Fresh/repeated
  migrations, historical upgrade paths, schema35→36, no backfill and marker99
  preservation passed. Log: `triage-final-release-schema.log`.

### Review and diagnosed issues

An independent read-only review of the full product diff found and rechecked
fixes for configuration audit side effects, fresh-captain required fields,
codepoint counting, UI filter preservation, schema readiness and the
configuration/source capture race. Final review found no remaining blockers.

Real API tests exposed the existing message cursor's `timestamp` cast losing its
zone when compared with retained `timestamptz` storage. Message-only cursor
comparisons now explicitly retain their RFC3339 timezone. Generated-SQL diagnosis
is in `triage-cursor-sql.log`; complete pagination passes under America/Chicago.
The existing task/event cursor expressions are intentionally unchanged.

### Blocked or unrun checks and delivery

- `./scripts/bazel test //:acceptance` stops because `.bazelrc.remote` / BuildBuddy
  configuration is absent (`triage-bazel-acceptance.log`). No local Bazel fallback
  was used. The new Go, ExUnit and packaged API tests are wired into acceptance.
- Supplemental existing `board_api_test.py` under America/Chicago stalls in its
  unchanged task-pagination loop and eventually hits the rate limit
  (`triage-final-board-api.log`). The new triage suite proves message pagination
  in that timezone; it does not claim to fix task/event pagination.
- Native browser/perceptual checks, physical interaction/Back/Forward and
  screenshots were not run. Rendered LiveView verification is not a pixel review.
- Archify, Lavish and OpenSpec executables are absent. Required new Archify source/
  export, tool validation and durable board-document upload remain unfinished;
  no generic HTML is claimed as their output. Board writes are not authorized.
- Hosted CI, Docker image builds, publication, production deployment/activation,
  #153 transport and any live equivalence/retirement proof are outside this run.
