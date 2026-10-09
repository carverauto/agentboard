# Historical receipt isolation

## Reproduction

Base: `7a98709f1b998ac0a7a6fb115763a346fcff9ead` (includes PR #193).
The regressions exercise the packaged API against a fresh TLS PostgreSQL database
with an ordinary, non-superuser application role and synthetic credentials.

1. Complete attempt A at epoch E, generation G using receipt R1. Reserve B at
   the same epoch, generation G+1. Retry R1 unchanged, then submit a valid new-key
   received/handled receipt for A.
2. Commit positive `not_submitted` evidence for A, then reserve B over A's still
   pending delivery. Submit late received/handled evidence for A.

Before the fix, case 1 releases B's active-attempt slot and changes A's timestamp.
Case 2 can consume B's delivery, acknowledge its Context source, replace A's
committed outcome and clear B's custody. Historical reconciliation also reports
`replay_allowed: true`. The first RED run produced nine failing assertions across
the two cases; the exact same-key retry control remained successful.

## Contract

- New-key, exact receipts for terminal older generations in the same binding
  epoch remain retained evidence. They have no delivery, source, outcome or
  binding effects. `historical` classifies the attempt when the response is sent;
  it does not reinterpret a receipt's original application.
- Same-key receipt retries retain first attribution/time. Exact terminal result
  retries retain committed outcomes. Existing epoch, recipient, membership,
  scope, hash and idempotency-content fences remain enforced.
- Historical reconciliation never authorizes replay. The immutable batch and
  canonical `not_submitted` outcome can independently prove an old journal is
  safe to retire. Missing or changed frozen evidence cannot retire it.
- The host applies the original PR #59 exact-batch validation to both rebound
  journals and historical generations within one epoch. Unresolved history
  remains blocked before native adapter or result I/O.

The TLS-backed host regression uses the exported `worker.Step` once per case,
with no native socket. Before the compatibility adjustment, non-submission
proof either left a rebound journal blocked or caused an unnecessary result
write during same-epoch recovery.

## Verification

All execution was in the disposable Linux assistant VM, using repository-pinned
Go 1.24.2, OTP 28.1, Elixir 1.19.4 and PostgreSQL 18.6 toolchains. No deployed board,
live worker, scheduler or native session was contacted.

- Production release compile/package: passed.
- ExUnit: 116 tests, zero failures.
- All Go tests and 54 focused TLS-backed history cases: passed.
- All Go race tests and `go vet ./...`: passed.
- Full cooperation API suite and both new historical-isolation cases: passed.
- Mattermost inbox/read/ack/wake/source-atomicity suite: passed.
- Decision requests/frozen wakes/recovery suite: passed.
- Full wake-intent/host-shadow suite, including the actual 120-second lease,
  retained uncertainty and lock-order regression: passed.

An initial wake run used an outdated fixture CLI without the `host` command.
It passed the lease proof before that harness mismatch. Rebuilding the CLI from
this branch and rerunning on a fresh database passed the complete suite.

Remote `./scripts/bazel test //:acceptance` was attempted and refused before
execution because `.bazelrc.remote` is unavailable. No local Bazel fallback was
used; full remote acceptance is unverified. Native adapter integration fixtures
were not rerun in this VM because Unix-domain sockets are unavailable; the
focused host proof uses TLS HTTP and requires no native adapter I/O.
