# Backlog refill

## Purpose

Keep eligible seats busy by assigning backlog cards deterministically, without a coordinator.

## ADDED Requirements

### Requirement: Refill flag defaults off
`AGENTBOARD_REFILL_ENABLED` SHALL default off and SHALL fully disable the refill job. While it is off, refill SHALL assign nothing and SHALL file no issues and open no tabs, including for a live fleet.

#### Scenario: Flag off
- **WHEN** the refill flag is at its default and a live fleet has idle seats and unassigned cards
- **THEN** no card is assigned and the board is unchanged

### Requirement: Deterministic selection
For each live activated fleet, while the refill flag is on, the refill job SHALL order unassigned open cards in the fleet's repositories by ascending priority (a lower number is more urgent), then creation time, then ID. Each pass SHALL assign at most one new card per seat. Across passes a seat SHALL be filled only up to its queue limit. The seat SHALL be chosen by shared seat eligibility, which applies availability, captain seat scope, waiting state and that queue limit. Security-labelled cards SHALL go only to seats whose scope includes that label. The job SHALL hold no cursor; each pass reselects the unassigned cards. A dry-run fleet SHALL NOT be assigned under this requirement.

#### Scenario: Two idle seats, three cards
- **WHEN** two eligible seats each hold no cards, three cards wait at priorities 0, 1 and 9, and one refill pass runs
- **THEN** the priority 0 and priority 1 cards are assigned, one per seat, and the priority 9 card waits

#### Scenario: Later pass fills toward the queue limit
- **WHEN** a later pass runs while one of those seats is still below its queue limit and the priority 9 card is still unassigned
- **THEN** that seat receives at most that one waiting card and no seat receives more than one new card in the pass

#### Scenario: Seat waiting on the captain
- **WHEN** a seat is waiting on a captain decision or is reserved or out of service
- **THEN** refill assigns it nothing

### Requirement: Assignment through the existing path
Refill SHALL assign through the existing assign action and send one idempotent `task_order` per assignment. Re-running after a crash SHALL converge on the same assignments without duplicate orders.

#### Scenario: Job restarts mid-pass
- **WHEN** the refill job crashes after assigning one of two cards
- **THEN** the next run assigns only the second card and sends no second order for the first

### Requirement: Claim deadline
The refill job SHALL return an assignment not claimed within the fleet's `claim_deadline` to the backlog with an attributed event. Repeated misses by one seat SHALL be shown in the fleet status digest.

#### Scenario: Seat never claims
- **WHEN** a seat leaves its ordered card unclaimed past the deadline
- **THEN** the refill job unassigns the card, the card is eligible for the next pass, and the miss is recorded

### Requirement: Dry run
While the refill flag is on, a fleet in dry-run mode SHALL record would-assign pairs and SHALL NOT assign, order or change any card. It SHALL file no issues and SHALL open no tabs. While the flag is off, it SHALL record nothing.

#### Scenario: Captain checks before going live
- **WHEN** refill runs for a dry-run fleet
- **THEN** the digest lists the pairs it would assign, the board is unchanged, no issue is filed and no tab opens
