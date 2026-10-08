# Design

## Context

See proposal.md (Why). Current state: no shared test-first instruction (each seat invents its own); the completion guard checks delivery state but not test evidence; PR CI does not run the Bazel suite (#97), so executed-vs-authored gaps surface post-merge (#113). The private reference `unified-math-tdd-protocol` (board doc 112) proves the cycle on a Rust math library; this design generalizes it and lands it in three slices with separate owners.

## Goals / Non-Goals

Goals: one skill file every seat reads; a guard condition keyed off an explicit opt-in marker; CI checks that fail at review time. Non-goals: changing how tests are written per language (the skill is language-neutral, examples are illustrative); whole-repo mutation runs; blocking docs/pins/Dependabot; re-litigating #97 (a stated dependency, not part of this change).

## Decisions

- **Skill as shipped file under `skills/`, installed via `agentboard skills install`** (slice 1) over a wiki page: versioned with the repo, present in every seat, zero runtime cost. Alternative (central docs site) rejected — seats need it in-context, offline.
- **Opt-in by label/flag, evidence on the task** (slice 2) over global enforcement: global would burn agent time on trivial changes; task-attached evidence keeps review seat-independent. The guard reads three named attachments plus a commit-order note; missing/incomplete attachment refuses `done` naming what is missing.
- **Parity from Bazel test result output (test.xml/BEP)** (slice 3) over runner-specific counters: one source of executed tests regardless of language. Discovered-authored count comes from source scan (test files × test functions/targets); mismatch or unexplained drop fails.
- **Changed-files-scoped mutation, report-only first** over whole-repo gating: bounded cost; gate once false-positive rate is tuned. Tool per language chosen at implementation (Go: go-mutesting/gremlins/ooze; Elixir: Muzak/exavier/Darwin; Rust: cargo-mutants) — listed as candidates, not requirements.
- **No new tables or migrations**: slice 2 evidence uses the docs store / attached context; slice 3 uses CI artifacts. Nothing in this design needs a schema number.

## Risks / Trade-offs

- [Skill ignored by seats] → The guard (slice 2) and CI (slice 3) are the teeth; the skill alone changes nothing measurable. Slice 1 ships first for immediate value, enforcement follows.
- [Evidence theater: attached but bogus] → Reviewers read evidence on the task; the deliberate-defect audit is hard to fake cheaply (defects tried + catching tests named). Residual risk accepted; captain reviews the first opt-in tasks.
- [Mutation cost/flakiness] → Changed-files scope + report-only start; gate only after tuning. Serviceradar rollout follows agentboard's tuned config.
- [Parity false positives (generated tests, build tags)] → Allow-list with reason for legitimately excluded tests; unexplained drops still fail.
- [#97 slips] → Slice 3 reports blocked-on-#97 instead of passing vacuously (spec requirement).

## Migration Plan

Additive and default-off: skill ships inert until read; guard only affects opt-in tasks; CI checks start report-only. Rollback: remove the skill file, drop the guard condition, disable the workflows. No data migration.

## Open Questions

None blocking. Tool picks per language and parity allow-list format are implementation detail inside the stated bounds.
