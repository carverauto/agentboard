## Purpose

Make full rigor checkable by the board: for explicitly opted-in tasks, `done` is refused until the failing-before run, the deliberate-defect audit, the mutation report, and the commit order are attached as task evidence a reviewer can read without seat access.

## ADDED Requirements

### Requirement: Explicit opt-in only

Full rigor SHALL apply only to tasks carrying an explicit opt-in marker (label or flag) set by the coordinator or captain. Tasks without the marker SHALL complete under the ordinary rules; the guard SHALL NOT demand rigor evidence for them.

#### Scenario: Ordinary task completes

- **WHEN** a task without the opt-in marker requests `done`
- **THEN** no rigor evidence is required and completion follows the ordinary rules

#### Scenario: Docs-only task with opt-in absent

- **WHEN** a docs, version-pin, or Dependabot task requests `done`
- **THEN** the guard never blocks it for missing rigor evidence

### Requirement: Completion guard requires three evidence artifacts

For an opted-in task, the guard SHALL refuse `done` until the task carries: (1) the failing-before run — output plus test count, showing each test failing for the intended reason; (2) the deliberate-defect audit — which plausible wrong implementations were tried (off-by-one, swapped branch, dropped error path, wrong default) and which tests caught each; (3) the mutation report — score plus the disposition of every survivor (killed by a new test or justified in writing).

#### Scenario: Done requested without mutation report

- **WHEN** an opted-in task requests `done` with the failing run and defect audit attached but no mutation report
- **THEN** completion is refused naming the missing mutation report

#### Scenario: Survivor unjustified

- **WHEN** a mutation report lists a surviving mutant with no killing test and no written justification
- **THEN** completion is refused naming the unjustified survivor

### Requirement: Commit order is auditable from the task

For an opted-in task, the evidence SHALL demonstrate that tests landed before the implementation: API-only commit, then suite commit, then implementing commits, with no test for a behavior landing after its implementing commit. The guard SHALL refuse `done` when the order cannot be shown.

#### Scenario: Test lands after implementation

- **WHEN** the evidence shows a test for a behavior committed after the commit implementing it
- **THEN** completion is refused naming the out-of-order test

### Requirement: Evidence readable without seat access

All rigor evidence SHALL live on the task (docs store or attached context) in a form reviewers and the captain can read without access to any seat's pane or worktree.

#### Scenario: Reviewer without seat access

- **WHEN** a reviewer opens an opted-in task's evidence
- **THEN** the failing run, defect audit, mutation report, and commit order are all readable from the task alone
