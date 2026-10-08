## Purpose

Catch silently-unrun tests and weak suites mechanically in CI: executed-vs-authored test-count parity under Bazel, and changed-files-scoped mutation testing, in agentboard and serviceradar.

## ADDED Requirements

### Requirement: Executed test count equals authored count

CI SHALL compare the tests discovered in source against the tests actually executed (from test result output), and SHALL fail on a mismatch or an unexplained drop. Tests that exist but silently never run — unregistered targets, filter exclusions, missing wiring, skipped jobs — SHALL fail the check.

#### Scenario: Test target not wired into the suite

- **WHEN** a test file exists but its target never executes in CI
- **THEN** the parity check fails naming the discovered-but-unexecuted tests

#### Scenario: Counts match

- **WHEN** every authored test executes and the counts agree
- **THEN** the parity check passes

### Requirement: Mutation testing scoped to changed files

CI SHALL mutation-test the files changed by the PR and SHALL report the score with every survivor. The check SHALL start report-only, then gate once tuned. Unbounded whole-repo mutation runs SHALL NOT be required.

#### Scenario: Survivor on a changed line

- **WHEN** a mutant on a PR-changed line survives in gate mode
- **THEN** the check fails naming the survivor until it is killed or justified

#### Scenario: Report-only mode

- **WHEN** mutation runs in report-only mode
- **THEN** the score and survivors are published without failing the check

### Requirement: PR CI runs the suite being measured

The parity and mutation checks SHALL run in PR CI over the Bazel suite whose results they evaluate, so a failure is reported at review time rather than on the next merge. This capability depends on PR CI running the Bazel suite (#97); without it, the checks SHALL report their dependency unmet rather than pass vacuously.

#### Scenario: Bazel suite not running in PR CI

- **WHEN** the prerequisite suite does not run for the PR
- **THEN** the rigor checks report blocked-on-#97 instead of passing
