# Coordinator inbox triage

## ADDED Requirements

### Requirement: Explicit six-way classification
The system SHALL normalize versioned typed metadata into status, CI, conflict, next-work, needs-judgment or captain-addressed, retaining the original category and attention. Explicit captain attention SHALL take precedence. The system SHALL NOT infer intent from body text, mentions, titles, nicknames, markers, model output or the fact that a recipient is the configured coordinator. Message kind SHALL remain distinct from classification.

#### Scenario: Routine report contains urgent words
- GIVEN a coordinator note has category status and attention routine
- WHEN its body mentions the captain, CI failure and a request for judgment
- THEN its normalized class remains status and it creates no coordinator webhook event.

#### Scenario: Explicit captain attention overrides category
- GIVEN a valid note has category ci or needs_judgment and attention captain
- WHEN the server captures its metadata
- THEN its normalized class is captain_addressed, the original fields remain auditable, and at most one logical escalation is eligible.

#### Scenario: Ordinary coordinator fallback
- GIVEN #122 sends a routine CI fallback to the configured coordinator without explicit captain metadata
- WHEN triage inspects the canonical source
- THEN coordinator recipient or the historical capture sentinel alone does not classify it as captain-addressed.

#### Scenario: Legacy or malformed metadata
- WHEN a legacy note omits triage metadata
- THEN enabled triage retains unclassified and unresolved visibility without guessing or acknowledging it.
- WHEN a new request contains unknown version, enum, key or malformed reference
- THEN it is rejected before any Message or triage mutation.

### Requirement: Canonical source provenance and scope
The system SHALL accept source-derived routing only from verified canonical producer associations. Client references and text markers alone SHALL NOT prove producer identity, source currentness or authority. Repository scope SHALL derive solely from the canonical task; taskless messages SHALL NOT derive scope from enrollment, sender or defaults. Triage SHALL preserve existing authentication and task_order admission rather than claim stronger enforcement than exists.

#### Scenario: Forged CI source
- GIVEN a caller names a real cooperation Event ID or pastes its exact fallback marker
- WHEN no trusted association establishes that this is the canonical producer Message
- THEN triage retains source-unverified/manual visibility and does not forward, select a worker or manufacture a source receipt.

#### Scenario: Taskless next-work versus taskless judgment
- WHEN a next-work message lacks a canonical assignment/task reference
- THEN it remains blocked without creating a repo-scoped wake.
- WHEN a taskless message explicitly requests judgment
- THEN it may reference its board/message IDs through the escalation adapter with no invented task or repo.

#### Scenario: Canonical scope or source changes
- GIVEN a captured message references a task or source whose current scope, assignment or lifecycle changes
- WHEN routing revalidates it
- THEN stale references cannot produce a new effect, and retained original evidence plus current blocked/superseded reason remain visible.

### Requirement: Atomic exact-Message capture and audit
The system SHALL retain one immutable triage identity per canonical Message ID and append-only disposition history. Source Message creation, initial triage/audit and local eligibility SHALL commit together in enabled capture modes. Same-ID retries SHALL return the retained result, while different immutable metadata SHALL conflict. Different Message IDs SHALL remain different occurrences, even with identical bodies.

#### Scenario: Concurrent capture and changed retry
- GIVEN two transactions attempt triage for the same canonical Message ID
- WHEN both have identical typed source metadata
- THEN one triage identity and its original result survive.
- WHEN a retry instead changes classification or source metadata
- THEN it conflicts without replacing the original audit or producing another event.

#### Scenario: Capture failure or lost creation response
- WHEN triage or local audit insertion fails during a new classified source transaction
- THEN the Message and every new dependent local projection roll back together.
- WHEN a client repeats the legacy message-creation POST and obtains a different Message ID
- THEN triage does not claim cross-message body deduplication or retrofit creation idempotency.

#### Scenario: Commit-order inversion
- GIVEN a lower Message ID commits after a higher one was processed
- WHEN pending-state repair or unresolved pagination runs
- THEN the late committed message is still discoverable; a high-water numeric cursor cannot silently skip it.

### Requirement: Existing owners retain deterministic routing authority
The system SHALL record informational status without inventing a reply or task mutation. CI/conflict SHALL adopt the existing #122 producer result and source identities, preserving its source-key election and exact-marker adoption. Triage SHALL NOT re-elect a recipient, run a second selector, or synthesize a Message for a worker Event return. Next-work SHALL adopt only an exact, current, already-authorized assignment and the existing #156 occurrence under existing scope/availability/admission rules.

#### Scenario: Status report
- GIVEN a status note has a valid canonical task-event reference or is a taskless informational report
- WHEN triage records it
- THEN its disposition records retained information, no task/heartbeat/lease is changed, and no invented response or wake to its sender is emitted.

#### Scenario: Worker and inbox election results
- GIVEN the CI/conflict source owner returns an existing worker Event, sent Message or adopted Message
- WHEN triage links that result
- THEN it retains the exact owner-provided identity without another Message, election or delivery.
- AND task-matched exact-marker adoption remains the owner's contract; markerless notes are never silently adopted.

#### Scenario: Worker-only Event has no inbox Message
- GIVEN the source owner elected worker delivery and produced no coordinator Message
- WHEN the Event is observed
- THEN no Message-ID triage row or synthetic canonical Message is created for that Event alone.

#### Scenario: Later worker enrollment
- GIVEN a source already has an inbox Message and current #122 bootstrap later creates one worker delivery
- WHEN triage reads its route evidence
- THEN it preserves both identities and reports current evidence without claiming a permanently frozen delivery mode or creating another source effect.

#### Scenario: Missing responsible owner
- GIVEN a CI/conflict source is undeliverable or its only fallback is the coordinator
- WHEN triage evaluates autonomous routine handling
- THEN it remains visibly blocked/manual, creates no routine coordinator webhook and cannot count as a successful retirement proof case.

#### Scenario: Exact assignment versus opportunistic refill
- GIVEN next-work names an assignment revision already authorized to the requesting sender
- WHEN canonical source, idle, availability and scope predicates remain valid
- THEN triage adopts the same existing idle_assigned reason hash.
- WHEN there is no exact assignment, several candidates or a changed recipient/revision
- THEN it remains blocked without selecting, assigning, claiming or renewing any task.

#### Scenario: Unsupported typed conflict or native admission
- GIVEN #169 current-order resolution or #150/#156 native admission is unavailable
- WHEN a source requests that route
- THEN typed metadata or a stored wake does not imply readiness; the specific unsupported reason remains visible and no substitute native input is sent.

### Requirement: Projection consistency without fabricated handling
The system SHALL persist coordinator-wake eligibility and honor it during initial capture, reconciliation and canonical-state/reservation-time admission. Channel transitions SHALL use the existing source lock and wake-election/CAS boundary so a retained old pending wake cannot remain reservable alongside a new #153 event. It SHALL preserve independent Mattermost behavior and typed source capture. Triage SHALL NOT acknowledge a Message, produce received/handled receipts, consume a decision or treat a durable route as native acceptance/handling. Existing accepted or uncertain effects SHALL block unsafe replacement.

#### Scenario: Reconciliation after generic-wake suppression
- GIVEN active triage safely recorded/routed a routine coordinator message or captured its escalation eligibility, including transport-unavailable pending state
- WHEN wake reconciliation later scans the still-unread Message
- THEN it honors the durable disposition and cannot recreate an independent generic coordinator wake.

#### Scenario: Reserve races with escalation enqueue
- GIVEN a generic coordinator wake was captured before a channel transition
- WHEN #156 reservation and triage escalation enqueue run concurrently
- THEN the canonical Message lock and existing election/CAS boundary elect no overlapping effects; an unreserved wake is durably fenced, while reserved/submitting/submitted/accepted/uncertain attempts block the new channel until owner reconciliation settles them.

#### Scenario: Historical not-submitted result
- GIVEN a retained generic wake has been durably excluded during an authorized channel transition
- WHEN its owning transport records a proven not_submitted result that returns the intent to pending
- THEN the durable exclusion survives, and later reservations cannot bypass it or create a duplicate coordinator effect.

#### Scenario: Typed capture and separate notices
- GIVEN a typed producer suppresses generic notice capture and captures its actual canonical Message with order metadata before commit
- WHEN triage integrates with that transaction
- THEN it does not replace the typed envelope with generic metadata or accidentally suppress an unrelated Mattermost projection.

#### Scenario: Read-only routed view
- GIVEN a message is recorded, routed, blocked or queued for escalation
- WHEN an agent lists raw unread messages or reads its triage projection
- THEN the operation does not change Message read provenance, cooperation receipts, task ownership or transport state.

#### Scenario: Preexisting uncertain coordinator wake
- GIVEN a shadow or legacy message already has an accepted or uncertain coordinator effect
- WHEN active routing is considered
- THEN the system retains that evidence and blocks duplicate-channel cutover until the existing effect is reconciled; a proven accepted/handled source remains on that existing channel and cannot be re-escalated, while proven non-submission may permit migration of an unhandled source.

### Requirement: Source-first transactional locking
Routing SHALL revalidate canonical sources under their existing owners' lock order before triage/outbox linkage. No triage consumer SHALL acquire #122 fallback election under worker/provision custody or introduce source locks below worker/attempt locks. Provider/native I/O SHALL run outside database locks.

#### Scenario: Enrollment races with source routing
- GIVEN concurrent #122 enrollment/bootstrap, source capture and triage repair
- WHEN the same source is evaluated
- THEN existing source-key and delivery uniqueness remain authoritative, lock-order tests show no cycle, and no second election or invented receipt is introduced.
