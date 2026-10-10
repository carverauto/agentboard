# Tasks

## Proposal and ownership

- [x] Read current source, #149/#161 and auth/decision/native boundaries.
- [x] Write the decision-only protocol proposal before implementation.
- [x] Receive parent-confirmed user-directed foundation clearance before product edits, without claiming transfer of #149's historical board assignment.
- [x] Confirm candidate schema 40 / migration 20261008004000 collision checks before creation; disclose that the unimplemented #168 allocator means this is not an atomic reservation.
- [x] Review the exact protocol, transaction lock order and configured-identity limits.

## Server and thin CLI

- [x] Implement explicit runner scope without widening existing scopes/defaults.
- [x] Add strict revision-1 non-consuming bounded tick and exact source reads.
- [x] Add immutable atomic batch/member handling receipts and idempotent retries.
- [x] Fence source, owner, credential, attribution and configuration changes.
- [x] Add dedicated bounded own-heartbeat without implicit tick liveness writes.
- [x] Add equivalent thin CLI commands and capability/schema checks.
- [x] Document pagination/restart, truthful incomplete-policy/native state and scope custody.
- [x] Correct stale full-CLI coordinator adapter claims without claiming live conformance.

## Verification and delivery

- [x] Cover pure validation/auth/CLI contracts and response count/byte limits.
- [x] Cover real PostgreSQL HTTP/CLI parity, non-consumption, cursors and late commits.
- [x] Cover atomic/concurrent/historical ack, revocation/source/owner/configuration races.
- [x] Prove immutable audit and unchanged source/task/lease/wake/worker receipts.
- [x] Prove additive migration upgrade and higher-marker preservation under normal DB role.
- [x] Run authorized VM Go/ExUnit/release checks; record any unavailable aggregate check.
- [ ] Obtain independent review, return full work/evidence to parent for authorized publication.

## Explicitly deferred

- [ ] #154 policy evaluation and #161 complete adapter rollout.
- [ ] #150/#156 native dispatch, #153 transport and #155 liveness supervision.
- [ ] Stable coordinator role-to-principal epoch handoff and alternate-adapter selftest.
- [ ] Any production credential issuance, setup, schedule, deployment or live cutover.
