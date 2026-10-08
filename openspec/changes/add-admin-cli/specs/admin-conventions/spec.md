## Purpose

Fix the contract every `agentboard admin` subcommand obeys — converge-only mutation, honest dry-run, machine-readable exit codes, and absolute secret hygiene — so operators can re-run anything safely and scripts can branch on exit status.

## ADDED Requirements

### Requirement: Converge-only mutation

Each subcommand SHALL read the current state, compute a diff, and apply only that diff. When state already matches, it SHALL write nothing. An existing identity SHALL be reused, never duplicated; existing tokens SHALL NOT rotate unless `--rotate` is given.

#### Scenario: Second run is a no-op

- **WHEN** every subcommand (and `admin apply`) runs a second time against a converged deployment
- **THEN** zero writes occur: no new identities, no token rotation, no env or overlay change, no rollout

### Requirement: Missing-token-file failure is explicit

If an identity exists but its token file is missing or unreadable, the command SHALL fail with a message telling the operator to rerun with `--rotate`. It SHALL NOT silently re-issue the token.

#### Scenario: Lost token file

- **WHEN** `admin worker create` finds the identity but cannot read the token file
- **THEN** it exits nonzero naming the file and the `--rotate` remedy, without calling provision

### Requirement: Dry-run makes no writes

`--dry-run` (alias `--plan`) SHALL perform no writes and SHALL print the full diff between current and desired state.

#### Scenario: Drifted state dry-run

- **WHEN** a mutating subcommand runs with `--dry-run` against drifted state
- **THEN** nothing is written and the printed diff names every pending change

### Requirement: Documented exit codes

Dry-run SHALL exit `0` (no changes), `2` (changes pending), or `1` (error). Apply SHALL exit `0` (converged), `1` (error, with nothing changed or a partial change reported), or `3` (rolled back).

#### Scenario: Clean dry-run

- **WHEN** `--dry-run` runs against converged state
- **THEN** it exits `0` and reports no changes

#### Scenario: Rollback exit code

- **WHEN** a rollout's verification fails and the previous pin is restored
- **THEN** the command exits `3` and the rollout record marks the rollback

### Requirement: No secret ever leaves the protected path

No token or operator-supplied secret value SHALL appear on stdout, stderr, logs, `--json` output, or board records. Tokens SHALL be written atomically to the given path with mode `0600`; the command SHALL refuse to overwrite an existing file without `--rotate` and SHALL refuse parent directories that are group- or world-writable. Output SHALL identify a token only by fingerprint or prefix (the #128 convention). Operator secrets (DB, registry, Mattermost, GitHub) SHALL be referenced by Secret name/key or file path and never read back or copied.

#### Scenario: Secret capture test

- **WHEN** stdout, stderr, `--json` output, and logs are captured across create, rotate, enroll, rollout, and error paths
- **THEN** no token or secret value appears in any of them, and the token file has mode `0600`

### Requirement: Structured JSON output

`--json` SHALL emit the computed diff and the result (applied changes, exit-code meaning) in a stable documented shape shared by all subcommands.

#### Scenario: JSON diff shape

- **WHEN** a mutating subcommand runs with `--json`
- **THEN** the output parses and carries the diff entries plus the result status, with no secret values
