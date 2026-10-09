## ADDED Requirements

### Requirement: Shared database-only branch-flow projection
The system SHALL supply every visualization from bounded persisted delivery reads with UTC as-of, source/currentness metadata, settings revision, tracked-coverage labels and per-section paging. Existing PR CI and merge qualification SHALL remain authoritative. Mount, polling refresh, interaction, search, pagination and configuration reads SHALL perform no provider I/O or enqueue provider collection. Counts SHALL be independent of the current PR page.

#### Scenario: Open and explore every visual surface
- **WHEN** a user opens /prs and filters, expands, focuses, searches, pages and dismisses views
- **THEN** provider spies observe zero GitHub requests and zero provider-job enqueues attributable to those actions

#### Scenario: Bounded counts and rows share a snapshot
- **WHEN** a projection returns table rows, repository totals and selection metadata
- **THEN** their source revisions are from a consistent bounded database read and an unavailable count is explicit rather than silently taken from the current twenty-row page

#### Scenario: Read cost exceeds budget
- **WHEN** a summary aggregate exceeds its measured statement budget
- **THEN** the response labels partial/unavailable data and keeps bounded fallback results without fetching all PR records into application memory

### Requirement: Exact identity and currentness provenance
PR relations SHALL use canonical repository/PR identity, exact head repository/ref/SHA, base repository/ref/SHA, expected base tip and a matched persisted snapshot generation/time. Unknown, stale, incomplete and policy-unknown evidence SHALL not qualify as green. Currentness SHALL be reevaluated on producer revision changes independently of view-refresh age.

#### Scenario: Snapshot does not match poll state
- **WHEN** a stored snapshot's head, base or observed_at differs from the current poll projection
- **THEN** its head metadata, checks and divergence cannot be combined into a current relation

#### Scenario: Base advances or PR is retargeted
- **WHEN** a named-base watch advances, head is force-pushed or the PR base changes
- **THEN** old pair-bound CI/conflict/count evidence becomes stale or unavailable immediately and stays so until a matching producer observation exists

#### Scenario: Successful checks have unknown required policy
- **WHEN** all retained checks succeeded but the producer's required-check policy remains unknown
- **THEN** branch-flow CI remains unknown rather than turning green

#### Scenario: Render refresh succeeds during provider outage
- **WHEN** the database read succeeds but provider observations are old or deferred
- **THEN** as-of reflects the read time and each evidence field still shows its original observed-at, age and stale/error qualification

### Requirement: Branch roles are explicit and provider metadata stays separate
The system SHALL persist captain-configured integration roles separately from validated provider-derived default-ref metadata. It SHALL preserve canonical repository identity, metadata observation time and repository-scoped monotonic observation generation, reuse existing background repository reads and never infer role, ref existence or health from a branch name. Unobserved role refs SHALL remain unknown.

#### Scenario: Repository uses a non-main default branch
- **WHEN** validated provider metadata identifies trunk as the default and no integration role exists
- **THEN** the graph labels trunk as default without inventing main or staging

#### Scenario: Configured branch has no observation
- **WHEN** a captain configures staging but no admissible workflow or base-watch evidence exists for it
- **THEN** the view labels it configured and health/tip unknown without causing collection on render

#### Scenario: Different workflow collectors complete out of order
- **WHEN** a slow collector for one run observed an old default while another run collector has already persisted a newer default
- **THEN** the repository-scoped generation fence rejects the obsolete shared-metadata write; incomparable per-run generations are insufficient

#### Scenario: Default metadata changes during collection
- **WHEN** before/after provider metadata disagree or a config revision is superseded
- **THEN** no mixed-role observation is committed as current evidence

### Requirement: Explicit scoped integration workflow intake extension
Before integration workflows may appear as observed branch-health evidence, the existing #114 producer SHALL be extended to admit only the verified default ref or the exact captain-configured integration ref for that repo, with only the resolution-only exception for retained unresolved keys specified below. It SHALL persist the accepted identity/configuration revision and fence commits against current configuration, producer generation, lease and canonical provider evidence. It SHALL reuse existing intake/admission/cooldown paths without a new UI-driven schedule and SHALL preserve existing cooperation gates.

#### Scenario: Current code ignores non-default runs
- **WHEN** the intake extension is absent or not activated
- **THEN** integration health remains explicitly unavailable even if a topology displays an integration role

#### Scenario: Valid staging run versus arbitrary branch
- **WHEN** canonical completed workflow runs arrive for the configured integration ref and an unrelated feature ref
- **THEN** only the configured ref is eligible for persisted integration health, and neither webhook body alone is trusted as CI evidence

#### Scenario: Configuration changes while run collection is in flight
- **WHEN** integration_ref or its revision changes before the reserved worker commits
- **THEN** the obsolete result cannot establish health for the new integration role and must reconcile under the current intake contract

#### Scenario: Previously ignored run exists
- **WHEN** a branch becomes configured after a run was marked not_default_branch
- **THEN** changing configuration does not automatically replay that run; only a new normal authorized intake cue can requeue it

### Requirement: Workflow obligations preserve branch-scoped recovery
Workflow evidence SHALL preserve repository/run dedupe, run-attempt ordering, immutable attribution, same-repository/branch/workflow recovery and retained unresolved failures independently of role or display changes. A green watermark SHALL be used for obligation recovery only, not whole-branch green verification.

#### Scenario: Success on a different branch
- **WHEN** staging succeeds while a main workflow with the same workflow id remains red
- **THEN** main's obligation remains unresolved and visible; the reciprocal case has the same isolation

#### Scenario: Older failure arrives after newer recovery
- **WHEN** a duplicated or delayed failure precedes the retained success watermark for its exact branch/workflow
- **THEN** no duplicate live obligation or spurious reopened red state is created

#### Scenario: Integration role removed while red
- **WHEN** a captain removes or changes the integration role
- **THEN** its unresolved runs remain globally visible as previously watched branch evidence until branch-scoped recovery, without deletion or synthetic resolution

#### Scenario: Later success on a removed role resolves only retained work
- **WHEN** a normal intake cue verifies a success for an exact unresolved repository/branch/workflow key on a no-longer-configured integration or formerly-default ref
- **THEN** resolution-only admission rechecks that key under its serialization lock, records that provenance and may resolve only ordered older obligations, without admitting new failures, reestablishing role health, enrolling the ref or changing schedules

#### Scenario: Removed role has no unresolved obligation
- **WHEN** a noncurrent-role cue arrives after its retained obligations are resolved or for an unrelated workflow
- **THEN** the resolution-only exception does not admit it

#### Scenario: No retained red after a success
- **WHEN** a workflow success clears the last retained obligation
- **THEN** the branch reads No retained red; current health unknown unless a separately approved complete-policy/current-tip producer can establish otherwise

### Requirement: Numeric divergence consumes the conflict producer contract
Ahead/behind numbers SHALL be consumed only from the #169 producer family under the exact-pair, generation, observed-at, completeness and provenance contract in design.md. Counts SHALL mean commits unique to head/base respectively. UI/projection code SHALL neither calculate them, infer them from qualitative mergeability, nor issue compare requests. Missing producer support SHALL remain an explicit implementation dependency and visible unavailability.

#### Scenario: Producer has only qualitative behind
- **WHEN** no complete numeric observation exists but mergeable_state is behind
- **THEN** all surfaces show qualitative behind with count unavailable and no synthetic positive integer

#### Scenario: Count matches current pair
- **WHEN** a complete fresh divergence observation matches canonical PR, head repo/ref/SHA, base ref/SHA, expected tip and current producer generation
- **THEN** ahead and behind may be shown numerically with observation time and evidence provenance

#### Scenario: Force push invalidates numbers
- **WHEN** head or base changes after numeric divergence was measured
- **THEN** the old numbers are omitted or explicitly last-known stale and cannot contribute to current health/ranking

#### Scenario: Repo trunk counts unavailable
- **WHEN** no producer evidence exists for the exact default/integration pair
- **THEN** repo-card divergence is unavailable and PR counts are not summed or substituted

#### Scenario: Producer enrichment would need provider calls
- **WHEN** adding numeric evidence requires additional GitHub compare requests
- **THEN** that work remains gated on a separate #169 producer budget/admission agreement and is not silently enabled by this visualization

### Requirement: Read-only conflict responsibility and compatibility
The new projection SHALL reuse existing RebaseFollowUp, submission and CI-obligation data without changing routing, deadlines, task orders, worker delivery, claims or leases. It SHALL distinguish immutable submitter, CI responsibility and rebase responsibility, keep terminal/history qualification, and support rollback to the current health/table presentation without dropping evidence.

#### Scenario: Cooperating worker is disabled
- **WHEN** a PR is conflicting while cooperation is off
- **THEN** the visualization shows the retained conflict evidence without creating a repair, wake or message through a view action

#### Scenario: Ownership changed after submission
- **WHEN** the original task has a new assignee but submission attribution and a repair responsibility are retained
- **THEN** the panel labels those distinct roles accurately rather than replacing immutable credit with current assignee

#### Scenario: Presentation rolled back
- **WHEN** the new presentation flag is disabled
- **THEN** the existing health panel/table can render the same retained obligations and PR state without deleting configuration, changing observation flags or resolving tasks
