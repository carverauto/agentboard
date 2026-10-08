## Purpose

Teach every fleet seat a shared, language-neutral test-first cycle in a light form usable on any task, so tests are written from spec scenarios before code, observed failing for the right reason, and never weakened to pass.

## ADDED Requirements

### Requirement: Five-phase cycle in order

Any task worked under the skill SHALL pass through the five phases in order — (1) stub the API, (2) write the full suite and watch it fail for the intended reason, (3) audit the suite against deliberate defects, (4) implement without weakening tests, (5) mutation-test the changed files — and SHALL NOT begin a phase before the previous phase's exit condition holds.

#### Scenario: Suite written before implementation

- **WHEN** a seat implements behavior under the skill
- **THEN** the test suite for that behavior exists in an earlier commit than the implementing commit, and no test for the behavior lands after it

#### Scenario: Phase order auditable after the fact

- **WHEN** the commit history for the work is read
- **THEN** the API-only commit precedes the suite commit, and the suite commit precedes the first implementing commit

### Requirement: Stubs fail loudly, never silently

Phase-1 API bodies SHALL compile and SHALL fail loudly when called (unimplemented panic/raise), SHALL contain no working algorithm, and the surface SHALL be derived from its callers rather than transcribed from an implementation being replaced.

#### Scenario: Stub called

- **WHEN** any test or caller invokes an unimplemented API body
- **THEN** it fails with an explicit unimplemented signal rather than returning a value

### Requirement: Failures observed for the intended reason

Every test SHALL be run against the unimplemented API and observed failing because the stub is unimplemented — not because of a compile error, a missing import, or an unrelated panic. The failing run and its test count SHALL be recorded.

#### Scenario: Failure run recorded

- **WHEN** the phase-2 exit is claimed
- **THEN** the failing run's output is recorded with the test count, and each failure is the unimplemented signal

### Requirement: Anti-circular expected values

No expected value SHALL come from the code under test, the same formula, or a helper sharing either. Acceptable sources: a hand-evaluated literal, a cited reference, a demonstrably different algorithm, an invariant (round trip, idempotence, conservation), or a property holding for all inputs. A port SHALL NOT be checked against the code it was ported from.

#### Scenario: Port checked against its source

- **WHEN** a test asserts ported behavior by recomputing through the original implementation
- **THEN** the suite is rejected as circular; the expectation must come from an independent source

### Requirement: Corners and error variants enumerated up front

Before implementation, the suite SHALL cover the domain's corner cases (empty, single element, boundaries, max/min, encoding, ordering, time) and SHALL construct and assert every error variant the API declares, identifying which variant came back.

#### Scenario: Declared error variant untested

- **WHEN** the API declares an error variant no test triggers
- **THEN** phase 2 is unfinished until a test triggers it and asserts the variant

### Requirement: Tests never weakened to pass

Once written, tests SHALL NOT be edited, deleted, skipped, or loosened to make the implementation pass. A genuinely wrong test SHALL be fixed in its own commit with a stated reason.

#### Scenario: Implementation fails the suite

- **WHEN** the implementation does not satisfy an audited test
- **THEN** the implementation changes, not the test; any test change lands separately with its reason stated
