# Provider-default metadata verification

## Bounded slice and base

This #185 increment was prepared on merged inspection PR #203 and rebased onto
main `a0081fe706833b416ee425967cf0648326c6fb1a` after PR #204 merged. It retains
validated default-ref metadata from the existing workflow collector and shares
one qualified role projection across cards, focused topology and PR inspection.
No integration configuration/intake, numeric divergence, new provider request,
new schedule, graph ancestry or branch-health success is added. The preview stays
off by default; this is not rollout, merge or deployment authorization.

The implementation uses a separately authorized disposable assistant-VM worktree,
not a maintainer workstation. Schema candidate `20261008003800` was checked
against fresh main, open PRs and available coordination context. #169 PR #204 added migration 32 and retained
required schema 37; its merged main does not allocate 38. Rebase conflict resolution
keeps its complete schema-readiness union, integration targets, conflict-history
upgrade assertions and PRLive conflict-order notices. This is a checked code allocation,
not an atomic live-board reservation. Shared-file rebases must preserve both
features and repeat relevant tests.

## Source and concurrency guarantees

- Each actual workflow reservation increments an audited repository-wide
  generation before HTTP. It immediately invalidates previous role qualification.
  Skipped work does not increment it.
- Metadata commits only after existing run and repository before/after response
  fences, the current run generation/lease, observation enablement and the captured
  repository generation agree. A slower different run cannot overwrite newer
  metadata. A newer failed collection cannot be replaced by an older success.
- Superseding metadata does not suppress an independently valid workflow failure
  or recovery. Metadata locking occurs after all recovery run-row locking, avoiding
  an inversion with reservation. Existing branch/workflow recovery keys remain.
- Raw mixed-case workflow identity and source FK remain exact; metadata uses its
  canonical repository key. Legacy unsupported identities skip optional metadata
  without blocking workflow observation. Stable ignored runs remain ignored and
  metadata alone does not add inventory eligibility.
- Source/time/generation qualification is shared. Disabled, missing, mismatched,
  stale (>180 seconds), future, superseded and failed reads cannot display a current
  default. Last-known provenance is separate; health and branch tip stay unknown.

The #169 PR/default-watch producer is now a second source, but has not joined the
workflow generation. Reads conservatively withhold current-role qualification in
`dry_run`/`apply` and when a repository has retained PR default-ref evidence, even
if that mode is later disabled. One indexed existence check inside the same
seven-row metadata query detects retained sources. Labels explicitly say
workflow-observed and retain historical provenance. Tests exercise all three modes,
retained conflicting evidence, recovery and zero additional provider requests.
This adds no producer or routing mutation; cross-producer integration remains open.

## Passed checks

- Nine new unit/component tests cover exact/case-sensitive/Unicode refs, source
  bindings, stale/future/disabled/superseded states, mixed-case provenance, seven-repo
  input bounds, read-failure degradation and visible current/last-known labels.
  The initial five source-qualification tests failed before implementation.
  The complete suite passes **188 ExUnit tests**, plus **18 interaction-hook tests**.
  The full-render synthetic row now includes the inherited `conflict_order: nil`
  field required by #204; production conflict-order rendering is preserved.
- `repository_metadata_test.py` fails on the baseline release's missing role
  projection, then passes against the implementation's real release, TLS provider
  and normal-role TLS PostgreSQL. It exercises two gated cross-run races (newer
  success and newer failure), retained red, run/repository before-after mismatch,
  run-generation/lease/off-switch rejection, pending/HTTP/budget errors, ignored
  cues, mixed-case and unsupported legacy identities, audits and unknown health.
- Real `PRLive` mount/params/refresh verifies a total database-read failure
  dequalifies every retained card/topology/role-map copy while preserving global
  red and provenance; recovery restores current roles. A separate metadata-table
  failure degrades roles without removing valid table/topology/attention reads.
  Whole-read failure uses an aborted fixture transaction, not an optional-section
  failure masquerading as a complete read failure.
- Existing overview, observed inspection, captain pin/CAS/expiry/rotation/receipt
  and signed default-workflow intake/recovery suites pass. One original workflow
  fixture generated a random key ending in a newline, which secret-file loading
  trims; the fixture now uses line-safe random hex material. This changes no
  product authentication or credential behavior. The inherited conflict-order
  sources, conflict-default-watch and conflict-routing suites also pass against
  the rebased release, including mode-off preservation and routing concurrency.
- Full release-schema upgrade/rerun/retention tests pass through the TCP fixture
  adapter, including actual schema 37→38 and future marker 99, no metadata backfill,
  preserved main #169 conflict-history assertions and readiness tables, retained
  red/pins/audit/jobs, valid source guards and populated metadata
  surviving repeated migration. The packaged release requires metadata-table
  presence and schema 38 while preserving higher markers.
- Go vet passes. Go tests and race tests pass with the newly inherited
  `TestStepConflictDispatchBeforeNativeIO` explicitly excluded: its three cases
  fail at Unix-socket creation under this VM's restrictions before exercising the
  product. That protected Unix-adapter contract cannot be replaced by the TCP
  PostgreSQL fixture. Full Go/remote acceptance remains unverified here.
  Test/production compilation, Tailwind, JavaScript bundle and OTP release pass.
  All 278 tracked/new web input files match the isolated build workspace. Existing warnings are not treated as errors.
- Independent review found and fixed mixed-case intake breakage and fresh role
  labels after whole-read failure. Final static review found no remaining blockers.
  Whitespace, test syntax and local documentation links are checked before publish.

## Measured bounds

A 60-repository fixture returns five requested metadata rows in exactly one
`SELECT ... WHERE id = ANY($1) LIMIT 7`, including an indexed PR-default
existence expression in that same query. The selected off-strip repo adds one;
table-only repos do not enlarge the metadata batch. Application maximum remains
five cards plus one focused repo plus one inspection repo. Reads cause zero
provider requests or audit writes. Successful/ignored collectors still use four
requests; the tested failure path still uses six. No cap or cadence increased.

The existing overview 1,000-repository/10,000-PR fixture uses 63 commands on the
small case and 77 on the large case, below its unchanged 85-command ceiling, with
181 returned SQL rows. Rich twenty-row parity has zero differences. The observed
inspection large fixture uses 78 commands for overview/focused, 101 for a selected
inspection and 88 for a table drawer; the same bounded topology/source lists and
all recorded EXPLAIN plans pass. These are single-host samples, not production
P95 or concurrency claims.

## Separate, unrun gates

- `./scripts/bazel test //web:repository_roles_test
  //build/integration:repository_metadata_test` stops before execution because the
  VM has no `.bazelrc.remote`/BuildBuddy configuration. No local Bazel fallback or
  credential access is attempted. Draft-head GitHub checks are reported separately.
- Actual browser/keyboard/screen-reader, narrow/zoom/theme/reduced-motion and
  perceptual acceptance remain unrun; protocol/render/hook tests do not replace
  them. Full production refresh-concurrency/P95 rollout proof is separate.
- Integration-role settings and #114 intake/resolution-only recovery, #169 numeric
  divergence, risk-ranked cards, complete visual-phase acceptance and authorized
  activation remain pending. No board write, external worker action, merge,
  deployment or runtime flag change is part of this slice.
