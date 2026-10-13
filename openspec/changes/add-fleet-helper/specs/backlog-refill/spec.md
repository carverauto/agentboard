# Backlog refill

## Purpose

Keep eligible seats busy by assigning backlog cards deterministically, without a coordinator.

## ADDED Requirements

### Requirement: Deterministic selection
For each activated fleet the refill job SHALL order unassigned open cards in the fleet's repositories by priority, then creation time, then ID, and assign each to a seat chosen by shared seat eligibility, which applies availability, captain seat scope, waiting state and the per-seat queue limit. Security-labelled cards SHALL go only to seats whose scope includes that label.

#### Scenario: Two idle seats, three cards
- **WHEN** two eligible seats each hold no cards and three cards wait
- **THEN** the two highest-ordered cards are assigned, one per seat, and the third waits

#### Scenario: Seat waiting on the captain
- **WHEN** a seat is waiting on a captain decision or is reserved or out of service
- **THEN** refill assigns it nothing

### Requirement: Assignment through the existing path
Refill SHALL assign through the existing assign action and send one idempotent `task_order` per assignment. Re-running after a crash SHALL converge on the same assignments without duplicate orders.

#### Scenario: Job restarts mid-pass
- **WHEN** the refill job crashes after assigning one of two cards
- **THEN** the next run assigns only the second card and sends no second order for the first

### Requirement: Claim deadline
An assignment not claimed within the fleet's `claim_deadline` SHALL return to the backlog with an attributed event. Repeated misses by one seat SHALL be shown in the fleet status digest.

#### Scenario: Seat never claims
- **WHEN** a seat leaves its ordered card unclaimed past the deadline
- **THEN** the card is unassigned, eligible for the next pass, and the miss is recorded

### Requirement: Dry run
A fleet in dry-run mode SHALL record would-assign pairs and SHALL NOT assign, order or change any card.

#### Scenario: Captain checks before going live
- **WHEN** refill runs for a dry-run fleet
- **THEN** the digest lists the pairs it would assign and the board is unchanged
