# Verification and operational boundaries

## Baseline and review

Implementation started from freshly fetched main
`540cb4349f2b45020199b19f8373405169bf7711`. A later fetch before final checks
confirmed the same main and no existing migration 41. Migration 41 is a checkout
candidate, not an external reservation. Proposal/design/spec/tasks preceded code
and were reviewed before implementation. Independent final source review covered
core/API/migration/evaluator/CLI and found no remaining must-fix after corrections.

## Passed supplemental disposable-Linux-VM checks

- `go test -count=1 ./internal/cli ./internal/client`: pass.
- `go test -race -count=1 ./internal/cli -run DecisionPolicy`: pass.
- Full Go invocation: CLI/client/config pass; worker package is blocked by the
  VM's denied AF_UNIX socket creation in existing conflict-dispatch fixtures.
- `MIX_ENV=test mix test --no-start`: 247 tests, zero failures, including 39
  evaluator tests and existing API-auth/coordinator tests.
- Normal-role, certificate-verified TLS PostgreSQL 18.6 with pg_textsearch 1.5.1:
  fresh schema 41 migration and actual 40→41 upgrade pass, including repeated
  migration, exact retained old-table data, higher aggregate marker preservation,
  empty policy/approval/ledger state and no active policy. Reserved actor collisions
  fail closed without rewriting or adopting any existing identity, even matching
  metadata; the freshly migration-owned identity is unchanged on repeat runs.
- Production Mix release and compiled Go CLI, with the committed policy HTTP
  integration fixture: all nine checkpoints pass. Actual AshOban jobs are drained;
  this is not an evaluator mock or source-text assertion.
- The shipped `docs/examples/decision-policy.json` validates against the actual
  schema. The final HTTP run additionally validates that exact file and its
  canonical digest.
- Existing packaged decision-request, wake-intent, coordinator-protocol and
  cooperation fixtures pass. This includes real captain/owner LiveView flows,
  consumer fallback, the actual 120-second wake expiry and delivery lock races.
- The complete legacy release-schema fixture passes, including retained
  historical evidence, repeat migrations and packaged CSS/JavaScript. This run
  preceded the final reserved-identity guard; the policy integration and upgrade
  suites were rerun after that guard. The legacy fixture's original bootstrap-
  superuser role is preserved; dedicated policy proofs use the normal app role.
- Python/shell syntax, changed-file formatting and `git diff --check`: pass.

The policy HTTP fixture covers strict schema and stable digests; unauthorized
lifecycle writes in auth off/observe/enforce; approval/version/CAS retries;
byte-stable zero-write reads in off/observe/enforce, including auth/audit/agent
rows and malformed read inputs; retained lifecycle observation; both execution
mode gates; post-block captured
source; human answer/recommendation/withdrawal, task/PR/owner/expiry and policy
currentness; in-flight captain proof/mode races; concurrent cross-version PR/day
budgets and CI intent; owner/API/captain-LiveView/duplicate-PR intake; coordinator
scope and exact-source projections; enqueue/ledger failure rollback; failed job
retry; answer/ledger pairing; normal-role UPDATE/DELETE/TRUNCATE rejection; and
prior-day budget accounting.

An injected Oban insertion failure produces HTTP 500 rather than normalized 503;
the fixture accepts either infrastructure status while requiring strict zero
committed source/audit/job state. The rollback invariant passes. No automatic
client retry or successful-answer claim is inferred from an infrastructure error.

## Existing recovery timezone finding

The unchanged recovery checkpoint fixture initially failed in this disposable
VM's inherited `America/Chicago` database timezone. The existing Ash predicate
casts `last_heartbeat_at` from `timestamptz` to `timestamp`, so it misses a stored
UTC heartbeat and a repeat capture violates `recovery_episode_incarnation`.
The exact original-main transaction resource list and unchanged capture body
reproduce the same failure. This is not treated as a passing initial run.

The exact unchanged fixture rerun with `TZ=UTC` before database initialization
passes under the normal role and certificate-verified TLS, including concurrent
idempotency, authorization, immutable audit, held-row preservation and new epoch.
No recovery code was changed or activation enabled. General recovery timezone
compatibility remains a separately identified baseline limitation.

## Required remote proof and constraints

`./scripts/bazel test //web:decision_policy_evaluator_test
//build/integration:decision_policy_test
//build/integration:decision_policy_upgrade_test` was attempted and stopped at
missing `.bazelrc.remote`. No credentials were copied and no local Bazel or
remote-execution bypass was used. Remote BuildBuddy acceptance and the exact
published-head hosted CI remain required before merge; VM evidence is additional.

Toolchains were restored from official checksum-verified sources. The
supplemental PostgreSQL fixture substitutes verified loopback TLS for unavailable
Unix sockets; app role is NOSUPERUSER/NOCREATEDB/NOCREATEROLE/NOREPLICATION/
NOBYPASSRLS. No maintainer workstation was used.

No product UI markup changed. LiveView promotion is functionally tested through
its real protocol. Product visual QA is not applicable. Portable architecture
HTML and retained JSON source passed deterministic structural checks; an attempted
document screenshot could not start Chromium because this VM denies AF_UNIX.
No screenshot or perceptual-browser proof is claimed. Architecture/proposal
artifacts are retained in the repository; board uploads were not performed.

## Deliberately incomplete operational and separate-issue scope

- #153 signed human escalation push/webhook is absent. Metadata explicitly says
  delivery unavailable. The coordinator decision poll must not be retired on
  this code result alone.
- #145 standalone YAML/offline evaluator/apply, local file locking and pending
  JSONL remain packaging work. The delivered CLI is JSON and server-authoritative.
- This first server revision uses explicit UTC days, a bounded regex subset and
  canonical requested_ci_runs. It does not claim general timezone or arbitrary
  regular-expression compatibility.
- No live board writes, policy import/approval/activation, deployment, credential
  changes, ownership changes, worker contact, native input or schedule cutover
  were performed. Existing recovery readiness remains gated.
