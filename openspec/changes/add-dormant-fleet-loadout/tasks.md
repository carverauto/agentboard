# Implementation acceptance

- [x] Verify additive schema-35 dormant storage, audit, binding and receipt invariants.
- [x] Verify captain-only read/full-replacement API and exact normalized retry behavior.
- [x] Verify canonical current managed scope references, immutable per-fleet bindings and cross-fleet configured-agent uniqueness.
- [x] Verify concurrent conflicts and rollback without changing existing workers or task/decision responsibilities.
- [x] Verify strict CLI show/set, protected auth for both actions, schema gating and error behavior.
- [x] Verify installed documentation links, Bazel inputs and Docker CLI source staging, including a missing-embedded-doc negative check.
- [x] Verify Settings capability expiry, conflict/double-submit/uncertain retry and real websocket save/reopen behavior.
- [x] Complete independent review and final assembled regression tests.

Broader fleet runtime/design acceptance remains incomplete. No activation, host/worker operation, catalog producer, role/readiness enforcement, Deck, publication or deployment is implied by this checklist.
