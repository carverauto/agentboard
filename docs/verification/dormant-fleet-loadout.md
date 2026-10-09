# Dormant FleetLoadout verification

## Scope and reviewed source

The implementation in `f0d4ecfac4d0c4962ae64937e8b1b6b5582516ef`, based on
`7db89eff7715c8d0883b53d830d95af40c0c3203`, adds named, captain-owned desired
configuration only. An independent read-only review of that immutable diff found
no concrete high- or medium-severity defect. It covered captain boundaries,
Settings events, normalized receipt replay, revision compare-and-set, configured
agent uniqueness across fleets, immutable seat bindings, reference locking,
atomic audit, dormant side effects, migration and packaging.

The follow-up changes add this report, complete the bounded implementation
checklist and include the embedded document in the Docker image workflows' path
filters. They do not change runtime behavior.

This is partial issue #60 delivery. Supported model/effort catalogs, trusted host
enrollment, automatic readiness/role gates, host reconciliation, worker activation
and Deck remain deferred. No live deployment or fleet activation was performed.

## Executed checks

All checks below ran on the explicitly authorized disposable assistant Linux VM,
using an ordinary linked worktree. Compilation and test databases used isolated
build/fixture directories; no maintainer workstation was used.

- Full Elixir suite: **111 tests, 0 failures**. Includes pure input validation and
  12 Settings event/component tests for expired/rotated capability, forged form
  fields, conflicts, interrupted exact retries, duplicate submits and dismissal.
- Production Phoenix release and pinned CSS/JS asset build: passed.
- `go test ./...`, `go test -race ./...`, `go vet ./...`: passed.
- Focused CLI tests: passed, including protected captain transport without actor
  environment values, strict JSON, schema gating and installed documentation.
- `fleet_loadout_api_test.py`: passed against the packaged release and real TLS
  PostgreSQL using the normal application role. Covers absent reads, no captain
  bootstrap, operational state snapshots, exact field/UTF-8/32-seat bounds,
  registered identity and scope references, per-fleet historical bindings,
  cross-fleet uniqueness, concurrent CAS/identical replay, retirement/harness and
  scope lock races, immutable binding/receipt/version evidence and historical
  replay versus fresh observations.
- The same integration suite exercises the real Settings websocket transport:
  public denial, signed captain unlock, named fleet editing and save, rendered
  desired/observed distinctions, dormant/unverified markers, duplicate-submit
  safety and fresh dismiss/reopen observations.
- Supplemental packaged CLI smoke: real show/set/exact replay passed using only
  the protected captain capability. Complete before/after agent records were
  unchanged. The fixture's existing `ci-accountability` seed was retained.
- Full release-schema suite: passed with a TCP-only fixture adaptation. Fresh
  migrations, repeated application, prior upgrade paths, explicitly staged
  schema 33→34 proof, schema 34→35 and higher-marker retention all passed.
  Existing operational/history bytes and populated immutable fleet evidence
  survive repeated migration. Empty migration creates no loadout configuration.
- Existing packaged regressions passed: `seat_scope_api_test.py`,
  `availability_api_test.py`, `cooperation_api_test.py`,
  `decision_requests_test.py` and `wake_intents_test.py`. The wake suite completed
  its real 120-second frozen-lease expiry and all remaining proofs.
- Docker CLI source staging: passed for 89 staged inputs and an offline
  Linux/amd64 Go build. Negative checks confirmed removal of the new document's
  COPY input fails `go:embed`, and removal of its `.dockerignore` exception is
  rejected. Both are included in the final source.
- Aggregate Bazel acceptance wiring contains both new Elixir targets and the new
  packaged API/Settings target. Workflow path filters cover changes to the new
  embedded documentation. `git diff --check` passed.

## Evidence and limits

Retained VM logs include `fleet-build.log`, `fleet-exunit.log`,
`fleet-release.log`, `fleet-go-tests.log`, `fleet-go-race.log`,
`fleet-go-vet.log`, `fleet-api-test.log`, `fleet-cli-api-smoke.log`,
`fleet-release-schema.log`, each named packaged-regression log, and
`fleet-wake-intents.log`. CLI Docker positive/negative staging logs are retained
separately. These are verification logs, not deployment evidence.

Early harness-only failures were corrected before the passing runs: an incorrect
wake script filename, a Unix-socket `createdb` fixture argument in this TCP-only
VM, and the supplemental smoke's incorrect assumption that migration seeds zero
agents. Interrupted wake runs were not treated as passing; the final run reached
normal exit 0 after its actual lease-expiry wait.

Remote Bazel acceptance and actual Docker image build/smoke were not run in this
VM because remote BuildBuddy configuration/credentials were unavailable. The
source-staging check is not an image build. No pixel-level browser review is
claimed; Settings verification uses rendered components and the real packaged
LiveView websocket boundary. Publication and remote CI remain separate gates.
