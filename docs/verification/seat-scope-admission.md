# Seat-scope admission verification

Implementation snapshot: `4f2fd3f8db596139d2e982f3b192569a7d4ec6b8`.
Base: `cc317f44e348101e3a8bfd79634cda22be35f43b` (schema 33).

This is the additive captain-managed repository/label admission foundation for
issue #60. It is not full FleetLoadout, role-policy, host, Deck or automatic
pickup delivery. The retained broader design remains separate. No live worker,
credential, policy, deployment or merge action was performed.

## Passed

- Go package tests, race tests and vet; CLI build and offline scope-reference
  installation regression. The local fixture binary used `-buildvcs=false`
  because the disposable worktree VCS-stamping subprocess failed; production
  build configuration was not changed.
- 95 ExUnit tests, including pure scope validation/matching and seven LiveView
  authorization/modal tests. Production Mix release, CSS and JavaScript assets.
- Packaged real HTTP and CLI scope suite with a non-superuser application role:
  strict replacement validation, captain authority, ordinary/coordinator write
  denial, coordinator read consistency, registration spoofing, every task
  admission route, exact label conjunction, raw-input-to-persisted-label cast
  regression, scoped orders/fanout, narrowing continuity, concurrent revisions,
  writer-versus-claim fencing, immutable attributed audit and provisioning bounds.
- Signed-session real LiveView websocket interactions: unauthorized forged edit
  events, captain save, stale conflict retaining draft, dismissal without save,
  reopen using newer state, and server-owned target/revision despite forged form
  fields. This is executable protocol/rendered-DOM proof, not visual browser QA.
- Full release-schema suite, including historical upgrades, actual schema
  33→34, pending higher marker 99 preservation, repeated migrations, unchanged
  prior board history, empty default policies, shape/FK constraints and immutable
  scope audit. The VM runner adapted only disposable fixture/bootstrap and
  `createdb` to TCP; migration/assertion code was unchanged.
- Cooperation retirement regression: retired identities cannot reserve new or
  replayed batches; exact result/receipt/reconciliation stays usable; explicit
  restore permits reservation again.
- Availability, wake-intent and decision-request regression suites.
- CI-accountability and PR-conflict suites: generated repair labels govern scope;
  repository/required-label mismatch leaves repair work Open and alerts captain;
  captain reassignment cannot bypass scope; matching managed seats receive work.
- Independent static review of the immutable implementation and follow-up fixes;
  no remaining high/medium finding reported. The review found and prompted the
  persisted-label cast guard, which is covered by the packaged regression.

## Evidence

Disposable VM logs (basenames):

- `scope-final-go-tests.log`, `scope-go-race.log`, `scope-go-vet.log`
- `scope-final-build.log`, `scope-combined-build.log`
- `scope-final-api-test.log`
- `scope-release-schema-test.log`, `scope-migration-smoke.log`
- `scope-cooperation-test.log`
- `scope-final-availability.log`, `scope-final-wakes.log`, `scope-final-decisions.log`
- `ci-seat-scope-routing-utc.log`, `rebase-seat-scope-routing.log`

All service/provider identities and capabilities in fixtures were synthetic.
Fixtures used isolated PostgreSQL databases and production release processes.
CI/rebase fixtures used UTC, and the PR-conflict fixture explicitly enabled its
synthetic observation path. These settings are test-local, not rollout actions.

## Not run / not claimed

- Remote Bazel `//:acceptance`: no remote configuration/BuildBuddy credential
  available; no local Bazel workaround was used.
- Native Unix-socket adapter fixtures: this VM denies AF_UNIX sockets. No live
  native input, host reconciliation, automatic claim scheduler or deployment.
- Visual browser screenshots/interaction QA; LiveView protocol/DOM proof is
  reported separately above.
- Lavish/OpenSpec portable rendering and Archify generation/validation: tools
  unavailable. Canonical Markdown/OpenSpec sources are provided, without
  fabricated generated artifacts.
- No standalone MCP execution: this repository has no separate MCP server.
  Integrations calling the central task API receive the same guards.

These passes do not establish operational completion or acceptance of the full
issue #60 design or deferred role/enrollment/readiness/host gates. Scope-only
matching is not automatic fleet eligibility.
