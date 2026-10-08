## Purpose

Give seats a one-line, verified path to install, upgrade, and uninstall the CLI and wire skills, with no manual verification steps and no shell or secret side effects.

## ADDED Requirements

### Requirement: One-line verified install

`scripts/install.sh` SHALL detect the platform, resolve the requested or latest version, verify `SHA256SUMS`, enforce archive path safety, verify the extracted binary reports the expected version, and install into `~/.local/bin` by atomic rename with a PATH hint. It SHALL NOT edit shell rc files or write config or secrets; it SHALL print env hints instead.

#### Scenario: Checksum mismatch

- **WHEN** the downloaded archive fails the checksum
- **THEN** nothing is installed and the script exits nonzero naming the mismatch

#### Scenario: Installed binary reports wrong version

- **WHEN** the extracted binary does not report the expected version
- **THEN** nothing is installed and the script exits nonzero

### Requirement: Non-interactive and reversible operation

The installer SHALL support `-y/--yes` and `AGENTBOARD_YES=1` for non-interactive runs (reading confirmation from `/dev/tty` when interactive), SHALL be idempotent on upgrade, and SHALL support `--uninstall`.

#### Scenario: Re-run at same version

- **WHEN** the installer runs while the requested version is already installed
- **THEN** it succeeds without changing the binary

### Requirement: Skills wiring only for verified harnesses

Skills installation SHALL use the installed binary's `agentboard skills install --dir` and SHALL run only for harnesses that are present AND have a verified discovery dir; otherwise it SHALL print manual lines. No hooks SHALL be installed by default.

#### Scenario: Absent harness

- **WHEN** a harness directory is not present
- **THEN** no skills write is attempted for it and manual instructions are printed

### Requirement: Hermetic test coverage

The installer SHALL carry a hermetic `sh_test` covering checksum failure, version mismatch, idempotent upgrade, and uninstall.

#### Scenario: Test run

- **WHEN** the installer test runs
- **THEN** all four behaviors are exercised without network or host mutation
