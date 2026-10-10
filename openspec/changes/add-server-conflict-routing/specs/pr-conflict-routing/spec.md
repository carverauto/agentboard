# Spec Delta

## Purpose

Route auditable, deadline-bound repairs for conflicting card-linked PRs while preserving source ownership, publication custody and genuine resolution evidence.

## ADDED Requirements

### Requirement: PR open or link triggers immediate conflict observation
The system SHALL evaluate mergeability when an eligible PR opens or is linked, without waiting for another merge. Only definitive current head/base evidence SHALL create a conflict order; unknown mergeability SHALL remain pending and retry.

#### Scenario: PR opens already conflicting
- **WHEN** a newly opened uniquely bound PR has definitive conflict evidence
- **THEN** the repair order is created immediately without a later merge or coordinator process.

#### Scenario: Null mergeability
- **WHEN** GitHub has not computed mergeability
- **THEN** the system retries within its provider budget and neither orders an unsupported conflict nor marks it clean.

### Requirement: Any relevant default-tip advance fans out to linked PRs
The system SHALL recompute every open linked PR in the affected repository when its default tip advances. A poller SHALL provide correctness when webhook delivery is absent. Old responses MUST NOT commit against a newer admitted base revision.

#### Scenario: Unlinked merge advances main
- **WHEN** a merge with no board card advances a repository tip and conflicts N open linked PRs
- **THEN** all N receive current-base evaluations and one live order each, subject to bounded provider scheduling.

#### Scenario: Restart during a paged sweep
- **WHEN** the service stops after committing a sweep page
- **THEN** it resumes remaining work and replay produces no duplicate live orders.

### Requirement: Current-base orders are idempotent and superseding
The system SHALL retain one live conflict order per PR and current default tip. Repeated evidence SHALL reuse its logical order identity; a newer tip SHALL supersede the prior version without stacking orders or postponing an earlier unresolved deadline.

#### Scenario: Repeat current-tip event
- **WHEN** a poll or webhook repeats the same tip and conflict
- **THEN** no second task order, repair card or wake identity is created.

#### Scenario: New tip while still conflicting
- **WHEN** the default tip advances during an unresolved conflict
- **THEN** current head/base evidence and order version supersede the prior version, obsolete deliveries are invalidated, and the earlier deadline is preserved.

### Requirement: Author-first orders have an explicit repair deadline
A conflict order SHALL name the PR, observed head/base, responsible full agent ID and configurable deadline, defaulting to 45 minutes. Known conflicting files SHALL be included; unavailable file information SHALL be labeled unknown. Orders and selected delivery sources MUST be durable independently of a coordinator's presence.

#### Scenario: Available author
- **WHEN** a new conflict has a current active author with no relevant captain hold
- **THEN** that author receives one repair-card order through the selected Event/Delivery or Message path, with the deadline and exact evidence identity.

### Requirement: Conflict delivery uses one selected source and effect
The system SHALL call #122's sole worker/inbox selector. Healthy worker mode SHALL use the existing Event/Delivery and bounded worker frame/receipt. Inbox fallback SHALL use one canonical Message and #156's existing typed inbox capture. Both SHALL carry the same closed order reference and enforce current order revision, recipient, assignment and watched identities. The system MUST NOT fabricate a second Message, wake enum, frame or native prompt for the other path. A delivery receipt MUST NOT grant publication or native custody authority.

#### Scenario: Healthy worker receives the order
- **WHEN** the selected recipient has a registered, enrolled, unpaused and live worker covering the repository
- **THEN** the existing Event/Delivery carries the typed order in its normal worker frame, with no duplicate inbox Message or wake effect.

#### Scenario: Worker unavailable and later enrolled
- **WHEN** a paused, revoked, stale or absent worker causes inbox fallback and subsequently becomes eligible
- **THEN** the retained canonical Message and exact-prior receipts suppress duplicate native delivery; bootstrap does not re-elect under a worker lock.

#### Scenario: Frozen source superseded
- **WHEN** an old worker batch or inbox intent references an order superseded by a newer tip, recipient or resolution
- **THEN** canonical currentness refuses the obsolete order without a branch write, fabricated authority or second effect.

### Requirement: Eligibility and deadlines route only the repair
At the deadline, or immediately for a stale, out-of-service or relevant captain-held author, the system SHALL select a free eligible repository seat using shared queue policy. It SHALL atomically transfer only the repair and invalidate old repair grants. Source ownership and author attribution MUST remain unchanged.

#### Scenario: Owner stale or waiting
- **WHEN** the author is stale or has an outstanding decision on a source task
- **THEN** the repair is eligible for immediate reassignment without waiting for its deadline or changing the source claim.

#### Scenario: Busy author reaches deadline
- **WHEN** the deadline expires while the conflict remains unresolved and the author is busy elsewhere
- **THEN** the shortest-queue eligible seat receives the repair-only assignment using deterministic tie breaking.

#### Scenario: Two jobs select a seat concurrently
- **WHEN** concurrent repair jobs compete for the last queue slot
- **THEN** transactional admission prevents oversubscription and the losing selection is reevaluated.

### Requirement: No eligible repair seat creates a captain escalation
The system SHALL retain a deduplicated captain-lane escalation when no eligible seat or safe custody capability is available. It SHALL reevaluate on relevant state changes and SHALL NOT silently wait, guess an identity or create a second PR.

#### Scenario: No free seat
- **WHEN** every repository seat is stale, unavailable, waiting or at its queue threshold
- **THEN** one current-order escalation names the evidence and exclusion reasons and remains visible until its disposition changes.

### Requirement: Resolution requires a changed mergeable head
Only a changed PR head confirmed mergeable against the current watched base SHALL satisfy a repair and credit its actual rebaser. Replies, status edits or head-check success SHALL NOT suffice. Closure, merge or a clean unchanged head SHALL cancel obsolete instructions without falsely crediting a repair.

#### Scenario: Owner repairs before deadline
- **WHEN** the author submits a different head confirmed mergeable against the current tip before escalation
- **THEN** the order is satisfied, pending replacement work is cancelled and no reassignment occurs.

#### Scenario: Same head becomes clean
- **WHEN** a base change makes the original head mergeable without any new head
- **THEN** the conflict is recorded cleared without repair and unnecessary instructions/grants are cancelled without rebaser credit.

#### Scenario: Stale clean response
- **WHEN** a clean observation belongs to an older base or head generation
- **THEN** it cannot satisfy or cancel the current order.

### Requirement: Routing has an auditable dry-run mode
Every sweep, order, deadline, selection, cancellation and escalation SHALL retain attributable evidence. Dry-run SHALL record planned dispositions without assignments, claims, messages, wakes, grants or GitHub writes. Disabling routing MUST preserve history and prevent new repair mutations.

#### Scenario: Evaluate in dry-run
- **WHEN** a conflicting cohort is evaluated with dry-run enabled
- **THEN** the ledger contains the planned identities and selection reasons while task ownership, inboxes, wakes and provider branches remain unchanged.

#### Scenario: Default-branch CI failure remains accountable
- **WHEN** default-branch CI fails after a merge during a conflict sweep
- **THEN** the existing merged-owner failure repair remains independently attributed and is not replaced or duplicated by conflict routing.
