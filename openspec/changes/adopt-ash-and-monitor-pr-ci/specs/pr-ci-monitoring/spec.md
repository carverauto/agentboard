## Purpose

Continuously observe CI for every board-linked pull request and retain trustworthy failure evidence and a visible remediation obligation.

## ADDED Requirements

### Requirement: Complete linked PR discovery
The monitor SHALL discover every valid GitHub PR linked to board tasks, including terminal tasks, with bounded pagination and repository-scoped credentials. Multiple tasks referencing the same PR SHALL share one monitored PR identity. Unsupported or inaccessible repositories SHALL remain visibly unmonitorable.

#### Scenario: PR belongs to a completed task
- **WHEN** a task was marked done before its linked PR failed CI
- **THEN** the PR remains discoverable and its failure is recorded independently of the immutable task

### Requirement: Current revision CI truth
CI SHALL be classified as passing, failing, pending, unknown or stale for the observed PR head/base and applicable configured check policy. Passing SHALL require complete fresh evidence, success of every expected required check and no current failed check. Missing checks, incomplete pagination, provider errors or older-revision success SHALL NOT imply passing.

#### Scenario: New head after a green build
- **WHEN** a PR receives a new commit or base revision while an earlier revision was passing
- **THEN** earlier evidence is retained as history and the new revision is pending or unknown until verified

#### Scenario: Only an unrelated check is green
- **WHEN** GitGuardian passed but a configured build/test check is missing
- **THEN** the PR is not classified passing

#### Scenario: Rerun supersedes a failure
- **WHEN** a newer attempt for the same check succeeds on the same current revision
- **THEN** the current aggregate uses the newer attempt and retains the earlier failure as history

### Requirement: Failure evidence collection
For failed checks the monitor SHALL retain check/job names, conclusions, timestamps, links and bounded diagnostic excerpts. BuildBuddy evidence SHALL be correlated to the repository and tested PR revision before attachment. Failed log retrieval SHALL preserve the known CI failure with a separate evidence-unavailable reason.

#### Scenario: BuildBuddy key cannot read logs
- **WHEN** GitHub reports failure but BuildBuddy returns permission denied
- **THEN** the table remains failing and shows the GitHub failure plus unavailable BuildBuddy evidence

### Requirement: Retry and restart safety
Polling SHALL use durable jobs, bounded concurrency, network/response limits and provider-directed backoff. Duplicate deliveries, restarts and overlapping polls SHALL NOT duplicate observations or follow-up work or let an older response replace newer revision evidence.

#### Scenario: Two workers overlap
- **WHEN** two workers observe the same PR concurrently and responses arrive out of order
- **THEN** only applicable current-generation evidence updates the current projection and a single failure obligation is recorded

### Requirement: Durable follow-up accountability
A newly observed CI failure SHALL create or update one active board follow-up per PR, referencing source tasks, responsible submitting agent and failure evidence. Original terminal tasks SHALL remain unchanged. Missing responsibility SHALL place work in a visible captain queue. Assignment SHALL NOT claim a lease, execute an agent, merge or change provider checks.

#### Scenario: Agent already moved on
- **WHEN** CI fails after the submitting agent completed its original task
- **THEN** a deduplicated follow-up identifies that agent and remains visible until handled or explicitly handed off

#### Scenario: Poll repeats the same failure
- **WHEN** repeated polls observe the same failure episode
- **THEN** they update evidence without creating another task or repeated inbox notification

### Requirement: Trusted provider access
Provider keys SHALL remain in server-side Secrets. The monitor SHALL call configured GitHub/BuildBuddy hosts with verified TLS, bounded redirects and scoped access. Arbitrary PR text or log URLs SHALL NOT determine a credential-bearing destination. Stored diagnostics SHALL be bounded/redacted and rendered as inert escaped text.

#### Scenario: Malicious details URL
- **WHEN** a PR check advertises a URL on an unconfigured host
- **THEN** no authenticated log request is sent to that host and evidence reports the rejected source
