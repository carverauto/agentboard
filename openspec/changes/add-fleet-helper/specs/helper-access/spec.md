# Helper access

## Purpose

Give chat bots and other helpers a narrow, optional credential so they can file work and read fleet state without becoming coordinators.

## ADDED Requirements

### Requirement: Narrow helper scope
A helper credential SHALL permit only: filing intake into captain-listed repositories, cancelling its own unstarted intake items, reading the fleet status digest, and setting a fleet's requested seat count within the captain's maximum. Every other write, including claim, named assignment, handoff, decision answers, lease release, merge, deploy and posting as another agent, SHALL be refused.

#### Scenario: Helper tries to assign a seat
- **WHEN** a helper calls the assign or handoff API
- **THEN** the request is refused and the board is unchanged

#### Scenario: Seat count above the cap
- **WHEN** a helper requests more seats than the fleet's `max_seats`
- **THEN** the request is refused with the cap in the error and the requested count is unchanged

### Requirement: The system does not depend on a helper
Backlog refill, seat supply, reaping, CI repair delivery and peer coordination SHALL run without any helper connected. A helper's disconnection or loss of context SHALL NOT stall assignment, launches or reminders.

#### Scenario: Helper goes silent
- **WHEN** no helper has called the API for a day
- **THEN** idle seats still receive backlog cards and wanted seats are still launched

### Requirement: Fleet status digest
`GET /api/v1/fleet/status` SHALL return a bounded digest per fleet: live, requested and maximum seats; backlog depth by priority; assignments unclaimed past their deadline; open CI repair obligations; launch intents by state; and recent intake results. It SHALL include no message bodies or credentials.

#### Scenario: Bot answers a progress question
- **WHEN** a helper reads the digest
- **THEN** it can report seats, backlog, stuck assignments and failing PRs from that single response
