# Proposal

## Why

Fleet seats ship defects that test-first discipline would have caught: PR CI does not run the Bazel suite (#97), so a broken `//internal/cli:cli_test` first surfaced on the next code merge instead of at review (#119 evidence). A shared, language-neutral rigor protocol — light everywhere, fully enforced where it matters — turns that luck into process.

## What Changes

- Slice 1: a shipped language-neutral test-first skill (five-phase cycle + cross-cutting rules), installed fleet-wide via `agentboard skills install`, usable on any task at no runtime cost.
- Slice 2: opt-in per-task full rigor (`full-rigor` label/flag): the completion guard refuses `done` until failing-before run, deliberate-defect audit, mutation report, and auditable commit order are attached to the task.
- Slice 3: CI checks in agentboard and serviceradar — executed-vs-authored test-count parity under Bazel, and changed-files-scoped mutation testing (report-only first). Depends on #97.
- Policy: full rigor for core logic (delivery/fence code, protocol parsing, security fixes) only; never docs, pins, or Dependabot. The light skill applies everywhere.
- No implementation until the captain approves this proposal in Lavish.

## Capabilities

### New Capabilities

- `test-first-skill`: the shipped skill and the light cycle every seat follows.
- `task-rigor-evidence`: opt-in evidence the completion guard requires before `done`.
- `ci-test-rigor`: CI parity and mutation checks over the built test surface.

### Modified Capabilities

None. No existing spec-level requirements change; the completion guard gains a new evidence condition defined entirely inside `task-rigor-evidence`.

## Impact

- New skill file(s) under `skills/`; no runtime code in slice 1.
- Board completion guard (slice 2) and CI workflows in agentboard + serviceradar (slice 3).
- Adapted from the private reference `unified-math-tdd-protocol` (board doc 112, not committed); generalized from Rust/math to any language.
