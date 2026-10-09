# Seat scope

## ADDED Requirements

### Requirement: Captain owns durable scope
The system SHALL store scope separately from self-reported registration and SHALL require verified captain capability for full-replacement writes with exact expected revision. It SHALL retain attributed immutable history.

#### Scenario: Concurrent scope replacement
- GIVEN revision 1
- WHEN two captain writes replace revision 1
- THEN one succeeds and one conflicts; the failed request adds no history.

#### Scenario: Unmanaged identity
- GIVEN no policy row
- WHEN scope is read
- THEN state is Unmanaged and revision is 0; manual legacy admission remains compatible and automatic matching is false.

### Requirement: New task admission respects scope
The system SHALL conjunct canonical repo matching, required-label ALL, allowed-label ANY when nonempty, availability and retirement for claim, assign, handoff and reclaim. Internal delivery assignments SHALL use the same admission.

#### Scenario: Security-only seat
- GIVEN repo `example/service` and required label `security`
- WHEN receiving work in another repo or without the exact label
- THEN reject without changing ownership, revision or audit; matching work succeeds.

#### Scenario: Captain task order
- GIVEN an explicit task and named active recipient
- WHEN the managed recipient does not match scope
- THEN reject the typed order; a captain broadcast excludes that recipient.

### Requirement: Policy does not abandon existing work
The system SHALL preserve existing renewal, release, progress and receipt/recovery after narrowing, but SHALL reject changing an owned task's routing fields to a result outside its managed owner's scope.

#### Scenario: Narrowed owner
- GIVEN a live owned task and a newly narrower captain scope
- WHEN the owner renews or reports progress
- THEN ownership continuity remains; new out-of-scope claims and routing edits reject.

### Requirement: Enrollment and retirement cannot bypass admission
Managed enrollment repositories SHALL be a subset of approved scope. Retired workers SHALL receive no new or replayed reservation batch while exact receipt and reconciliation remain usable.
