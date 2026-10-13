# Helper access

## Purpose

Give chat bots and other helpers a narrow, optional credential so they can file work and read fleet state without becoming coordinators.

## ADDED Requirements

### Requirement: Narrow helper scope
A helper credential SHALL permit only: filing intake into captain-listed repositories, cancelling its own unstarted intake items, and reading the fleet status digest. The captain sets `requested_seats` and `max_seats`. The helper SHALL NOT set either. Every other write, including claim, named assignment, handoff, decision answers, lease release, merge, deploy and posting as another agent, SHALL be refused.

#### Scenario: Helper tries to assign a seat
- **WHEN** a helper calls the assign or handoff API
- **THEN** the request is refused and the board is unchanged

#### Scenario: Helper tries to set seat counts
- **WHEN** a helper requests a change to `requested_seats` or `max_seats`
- **THEN** the request is refused and both counts stay as the captain set them

### Requirement: Helper routes require a helper token
Intake, intake cancel, intake status and `GET /api/v1/fleet/status` SHALL require a captain-issued helper token or the captain, even when `agent_auth_mode` is off. This SHALL NOT turn on global authentication. Other routes keep their existing rules. Helper calls SHALL be subject to the existing API rate limits.

#### Scenario: Auth mode off
- **WHEN** `agent_auth_mode` is off and a caller without a helper token or captain credential reads the fleet status digest
- **THEN** the request is refused and no digest is returned

### Requirement: The system does not depend on a helper
Backlog refill, seat supply, reaping, CI repair delivery and peer coordination SHALL run without any helper connected. A helper's disconnection or loss of context SHALL NOT stall assignment, launches or reminders.

#### Scenario: Helper goes silent
- **WHEN** no helper has called the API for a day, the refill and seat-supply flags are on, and a live fleet has requested seats and host cap above its live seats
- **THEN** idle seats still receive backlog cards and wanted seats are still launched

### Requirement: Fleet status digest
`GET /api/v1/fleet/status` SHALL return a bounded digest per fleet: live, requested and maximum seats; backlog depth by priority; assignments unclaimed past their deadline; open CI repair obligations; launch intents by state, including dry-run would-launch intents; and recent intake results. It SHALL include no message bodies or credentials.

#### Scenario: Bot answers a progress question
- **WHEN** a helper reads the digest
- **THEN** it can report seats, backlog, stuck assignments and failing PRs from that single response
