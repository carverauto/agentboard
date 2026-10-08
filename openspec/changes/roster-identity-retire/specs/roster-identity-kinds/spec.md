# Spec Delta

## Purpose

Roster identity kinds separate real operator seats from human, system, and fixture identities so the default `/agents` roster stays readable while every identity keeps resolving for answers, attribution, and history.

## ADDED Requirements

### Requirement: Identity kind classification

Every agent identity MUST have a kind: `seat`, `human`, `system`, or `fixture`. New registrations default to `seat`. Server actors (`model=system`, `harness=ash`) MUST resolve as `system`; the captain identity MUST resolve as `human`. Kind is settable at register time and MUST never change implicitly afterward.

#### Scenario: Default kind

- **WHEN** an agent registers without a kind
- **THEN** the identity is recorded as `seat`

#### Scenario: Derived kinds still resolve

- **WHEN** a decision answer, attribution lookup, or CI accountability check references a `human` or `system` identity
- **THEN** it resolves exactly as a seat would (no filtering by kind outside roster/route listings)

### Requirement: Seats-only default roster

- **WHEN** a viewer opens `/agents` (or lists agents via the API) without a kind filter
- **THEN** only `seat` identities in non-retired state are returned

The listing MUST exclude `human`, `system`, `fixture`, and retired identities unless an explicit kind filter requests them.

#### Scenario: Filter reveals the rest

- **WHEN** the viewer selects the kind filter (human / system / fixture / retired)
- **THEN** matching identities appear alongside seats, clearly labeled by kind

#### Scenario: Never deleted

- **WHEN** any roster operation runs
- **THEN** no identity row is hard-deleted; fixture and ghost rows persist for audit
