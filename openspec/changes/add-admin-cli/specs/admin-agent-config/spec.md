## Purpose

Replace hand-edits of deployment env vars and the multi-step manual `agent register` + bot check with idempotent CLI subcommands for agent registration and server configuration.

## ADDED Requirements

### Requirement: Wrapped agent registration

`admin agent register <agent-id> --harness H --model M` SHALL wrap the existing `agent register` flow and additionally report the agent's bot and availability state (per #82/#118 lazy bot creation and #81 availability).

#### Scenario: Register reports bot state

- **WHEN** `admin agent register` completes for an agent
- **THEN** the output includes the registration result plus the bot/availability state without duplicating `agent token` behavior (#128)

### Requirement: Coordinator-ID get/set

`admin config get|set coordinator-id <agent-id>` SHALL read or converge the coordinator ID (today the hand-edited `AGENTBOARD_COORDINATOR_ID`, see #100/#125). Setting the same value twice SHALL be a no-op.

#### Scenario: Set same coordinator twice

- **WHEN** `admin config set coordinator-id` runs twice with the same value
- **THEN** the second run writes nothing and reports converged

### Requirement: CI-policies get/set

`admin config get|set ci-policies --file policies.json` SHALL read or converge the CI certification policies (today the hand-edited `AGENTBOARD_CI_POLICIES` JSON env var, #124). The `--file` input SHALL be validated as JSON before any write.

#### Scenario: Invalid policies file

- **WHEN** `admin config set ci-policies --file` is given a file that is not valid JSON
- **THEN** nothing is written and the command exits nonzero naming the parse failure

### Requirement: Token conventions reused, not duplicated

`admin agent` output that references tokens SHALL use the #128 fingerprint/prefix convention and SHALL NOT implement separate issue/rotate/list commands; those stay in `agent token` (#128).

#### Scenario: No duplicate token commands

- **WHEN** the `admin` command tree is listed
- **THEN** no `admin agent token ...` subcommands exist
