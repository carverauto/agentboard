# Tasks

## 1. Proposal review (this change; no implementation)

- [ ] 1.1 Settle command names, `apply -f` schema, target backends, exit codes, secret handling, and rollback semantics in this proposal; verify every #138 acceptance bullet maps to a requirement above.
- [ ] 1.2 Validate with `openspec validate --strict`; verify zero errors.
- [ ] 1.3 Open in Lavish for captain review, upload portable doc, send the review URL to the coordinator; STOP until approved.

## 2. Implementation (after captain approval only)

- [ ] 2.1 Add `internal/cli/admin*.go` + Bazel targets and wire the `admin` group in `root.go`; verify `agentboard admin --help` lists the settled tree with no `agent token` duplicates.
- [ ] 2.2 Implement worker lifecycle (create-or-reuse + `0600` token file, converge-only enroll, repeat-safe revoke) behind the captain capability; verify create-twice/enroll-twice/revoke-twice are no-ops.
- [ ] 2.3 Implement `admin agent register` wrapper (bot/availability report) and `config get|set` for coordinator-id + ci-policies (JSON-validated); verify set-same-value-twice is a no-op and invalid policies files are refused.
- [ ] 2.4 Implement `admin rollout` (digest gate → backup → same-digest migration Job → roll → verify + soak → auto-rollback, exit `3`) for kustomize and compose targets; verify same-digest rerun is a no-op, failed verification rolls back, and backup precedes migration.
- [ ] 2.5 Implement read-only `admin doctor` and `admin apply -f` through the same code paths; verify doctor writes nothing and apply-twice is a no-op.
- [ ] 2.6 Add idempotency, plan-mode, and no-secret-output tests (stdout/stderr/`--json`/logs capture; `0600` assertions; exit-code matrix on clean/drifted/partial states); verify they pass via CI Bazel targets (`--config=remote`) with no raw BEP in evidence (#132).
- [ ] 2.7 Write `docs/setup/admin.md`, rewrite `docs/deploy/reference-farm01.md` rollout steps as `admin` invocations with an example config, add the `k8s/overlays/example` sample config; verify #127 installs this CLI unchanged.

## 3. Closeout

- [ ] 3.1 Record CI status on the card and link the implementing PRs; verify links resolve.
