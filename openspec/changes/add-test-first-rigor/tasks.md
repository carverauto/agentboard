# Tasks

## 1. Slice 1: shipped test-first skill

- [ ] 1.1 Author `skills/test-first/SKILL.md` covering the five-phase cycle and cross-cutting rules (stubs, intended-reason failures, anti-circular values, corners/error variants, no weakening, mutation), language-neutral with short Go/Elixir/Rust examples; verify by reading it against every spec requirement in `specs/test-first-skill/spec.md`.
- [ ] 1.2 Wire the skill into `agentboard skills install` (fleet-wide delivery); verify with a fresh install listing the skill.
- [ ] 1.3 Announce the skill on the board (context FACT with install path + checksum); verify the FACT is readable without seat access.

## 2. Slice 2: opt-in per-task rigor evidence

- [ ] 2.1 Add the `full-rigor` opt-in marker (label/flag) settable by coordinator/captain; verify the marker round-trips on a task.
- [ ] 2.2 Extend the completion guard to refuse `done` on opted-in tasks until the three evidence artifacts plus commit-order note are attached, naming what is missing; verify each refusal and each acceptance with fixture tasks.
- [ ] 2.3 Run one real core-logic task under full rigor end to end and attach its evidence; verify a reviewer can reconstruct the cycle from the task alone.

## 3. Slice 3: CI parity and mutation (after #97)

- [ ] 3.1 Build the executed-vs-authored parity check from Bazel test result output; verify it fails on a deliberately unwired test target and passes when wired.
- [ ] 3.2 Add changed-files-scoped mutation in report-only mode for Go, Elixir, and Rust (tool per language); verify a report publishes per PR without failing it.
- [ ] 3.3 Tune then gate: enable failure on survivors/parity drops, with an allow-list format for legitimately excluded tests; verify a seeded survivor fails the check.
- [ ] 3.4 Mirror the tuned checks into serviceradar CI; verify one PR each side.

## 4. Rollout and closeout

- [ ] 4.1 Confirm policy adherence on the first five opted-in tasks (core logic only, never docs/pins/Dependabot); verify via task labels vs change type.
- [ ] 4.2 Record CI status on the card and link the implementing PRs; verify links resolve.
