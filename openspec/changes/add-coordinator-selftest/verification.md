# Verification evidence

Verified on 2026-10-11 in an isolated disposable Linux worktree based on
`50dc29f9ed1e6d9e74609f7eecf84c813a8c0760`.

- `go test ./internal/cli ./internal/client`: passed.
- `go vet ./internal/cli ./internal/client`: passed.
- `git diff --check`: passed.
- Independent review reproduced and then verified fixes for two regressions:
  oversized wire responses that could shrink during credential redaction, and
  invalid Unicode that credential redaction could normalize. Fresh-binary
  loopback checks passed for clean, reflected-credential and malformed cases.
- The full supplemental packaged `coordinator_protocol_test.py` suite passed
  against real PostgreSQL fixtures and the freshly rebuilt CLI. Coverage
  includes authenticated read-only selftest, empty/nonempty pages, scope and
  identity rejection, offline no-network behavior, and coordination-state
  invariance excluding ordinary bearer last-use telemetry, alongside existing
  protocol and concurrency coverage.
- Tested CLI binary SHA-256:
  `b1676b32719ead8d5ae6a7207ed71b26f1ee3ac784667d6a241de999abaee926`.

## Limits

The complete `go test ./...` run could not pass in this environment: the existing
worker `TestStepConflictDispatchBeforeNativeIO` Unix-domain socket fixtures
failed with `socket: operation not permitted`, including after the permitted
sandbox escalation retry. No tests were changed or skipped to hide the failure.

Required remote Bazel/CI verification remains unrun: remote configuration and
credentials were unavailable. No local Bazel fallback was attempted. The
supplemental disposable-host results do not replace required remote checks.

No live coordinator was activated or enrolled, no native schedule or real
captain delivery was exercised, and no live received/handled conformance or
persisted badge is established by these results.
