# Wake intents: current proof boundary

Base: `fee18ac222e1ceeab326d436edf5515c47adce44` (PR #189). The seven
preserved implementation commits were rebased without discarding their history.
This checkpoint supersedes the earlier generated visual exports and interim
source-read reports, which remain available in Git history.

## Implemented contract

- Durable audited occurrence/attempt identities with unique constraints and
  transactional capture rollback. Pending-state discovery has no high-water mark.
- Board DMs require canonical task repository scope. Taskless legacy DMs remain
  readable in the inbox and are never assigned by enrollment order/cardinality.
  Scope is filtered before bounded pages; changed canonical scope suppresses the
  old occurrence. Changing subscriptions cannot relabel retained identities.
- Answered decisions reuse their original wake/event, including fenced fallback
  adoption. Generic answer-message capture is suppressed.
- Live claim warnings identify exact expiry; authorized idle assignments identify
  the assignment event revision. Renewal/claim/terminal transitions invalidate them.
- Source-first wake reservation, exact recipient/enrollment/binding/generation
  fences, immutable cooperation batches and separate transport/handling receipts.
  Historical terminal retries and reconciliation cannot regress newer attempts.
- Adopted non-decision delivery reservation belongs solely to the source-fenced
  wake endpoint. Generic cooperation reservation, including its fairness slot,
  excludes those deliveries while leaving them inspectable.
- Existing PR #189 exact-version Mattermost recovery/delivery/receipt ownership is
  retained. Worker-scoped recovery ends before event/audience routing starts.
- Availability and disabled/paused/unsupported admission park sources. Uncertain
  or expired delivery stays unreplayable without positive non-submission evidence.

## Validation

Disposable assistant Linux VM, real PostgreSQL 18.6, OTP 28.1/Elixir 1.19.4,
Go 1.24.2. No maintainer workstation builds, native socket calls, credentials,
enrollment or deployment.

Verified on 2026-10-09 against product commit
`a9d86df5e7faec53f36cd32e4d881a95292ad9f0`:

- `go test ./...`, `go test -race ./...`, `go vet ./...`: passed.
- Production CLI build: passed with `-buildvcs=false` because this disposable
  linked-worktree environment made Go probe the shared parent Git directory.
- ExUnit: 78 tests, zero failures. Production release and CSS/JS assets built.
- Packaged `wake_intents_test.py`: passed with both fixture database-owner and
  normal application roles, including the actual 120-second lease clock.
- Packaged cooperation, decision, availability and Mattermost inbox suites:
  passed. The Mattermost suite includes PR #189's exact-version CLI/receipt,
  edited-version, concurrent recovery and generation-fence contracts.
- Actual schema31-to33 upgrade preserves canonical sources and prior audit bytes;
  repeated migrations preserve populated wake/attempt/audit bytes. Audit mutation
  refusals, identity uniqueness, state/fence constraints and retained-evidence
  foreign keys passed. A pending wake migration also preserves a higher existing
  aggregate schema marker via `GREATEST`.
- Independent source review: four additional correctness findings were fixed and
  covered by regressions; focused re-review found no remaining must-fix issue.

The repository's remote Bazel aggregate and actual native adapter fixtures were
not run; see the explicit limitations below.

The packaged regression suite covers transactional capture/reservation rollback,
concurrent capture and two-daemon election, independent hashes, retained audit,
lower-ID late commit, authentication/scope, exact reservation retry, canonical
handling, source invalidation, fallback election, actual lease expiry,
old-incarnation callback, historical attempt isolation, dry-run host custody and
subscription reorder/change with an excluded backlog larger than a scan page.

## Explicitly unavailable

- #123 authoritative blocker dependency events: `blocker_shipped` is reserved but
  unsupported; free-text blocker notes never create a wake.
- #150 shared safe-input/quota admission and actual guarded Herdr delivery: native
  host delivery remains dry-run/default-off. Quota observations are not authority.
- A second Mattermost occurrence queue: existing #189 exact-version cooperation
  delivery remains the sole producer and owner.
- #169 current-order resolver and #154/#155 recovery policy/escalation producers.
- Actual native socket rejection/acceptance/reconnect proof, production enrollment,
  service/hook activation, recovery/restart and replacement of the current nudger.

Remote Bazel cannot run without remote configuration/credentials. Native adapter
Unix-socket fixtures cannot run in this VM because AF_UNIX creation is denied.
These are verification limits, not claims of successful native delivery.
