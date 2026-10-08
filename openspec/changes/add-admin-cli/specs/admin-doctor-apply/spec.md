## Purpose

Give operators a read-only drift overview and an optional declarative path that converges through the same tested subcommands — no second implementation of any mutation.

## ADDED Requirements

### Requirement: Read-only drift report

`admin doctor` SHALL report drift across worker identities, agent registration/bot state, config values, and deployment pins, and SHALL make no writes.

#### Scenario: Doctor on converged deployment

- **WHEN** `admin doctor` runs against a fully converged deployment
- **THEN** it reports no drift and exits `0` without writing anything

### Requirement: Declarative apply converges through subcommands

`admin apply -f agentboard-admin.yaml` SHALL converge the declared workers, agents, config, and pins by invoking the same code paths as the individual subcommands (no separate mutation logic). A second apply of the same file SHALL be a no-op.

#### Scenario: Apply twice

- **WHEN** `admin apply -f` runs twice with the same file against a converged deployment
- **THEN** the second run makes zero writes

### Requirement: Apply file schema is settled here

This proposal SHALL settle the `apply -f` file schema (top-level sections, required vs optional fields, target-backend selection, secret references by name/path only — never inline values).

#### Scenario: Secret inline in file

- **WHEN** an apply file contains an inline secret value where a reference is required
- **THEN** validation rejects the file before any subcommand runs, naming the offending field
