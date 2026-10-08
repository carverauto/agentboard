## Purpose

Cut repeatable, verifiable CLI releases from version tags so every seat can install and upgrade from published artifacts instead of hand-built binaries.

## ADDED Requirements

### Requirement: Tag-triggered gated releases

A push of a `v*.*.*` tag SHALL start a release; `workflow_dispatch` SHALL be able to re-run it. The pipeline SHALL proceed only when the tag points at main, `//:acceptance` is green on BuildBuddy, and the CLI reports the tag version. Cross-compiles SHALL cover darwin/linux × arm64/amd64 on BuildBuddy remote, never on a seat machine.

#### Scenario: Tag off main

- **WHEN** a version tag points at a commit not on main
- **THEN** no release is published and the run reports the gate that refused

#### Scenario: Version mismatch

- **WHEN** the built CLI reports a version different from the tag
- **THEN** no release is published and the run reports the mismatch

### Requirement: Published artifacts with checksums

Every release SHALL publish `agentboard-<ver>-<os>-<arch>.tar.gz` for all four platform pairs plus a `SHA256SUMS` covering them, with release notes, under Semver. Only the captain SHALL cut tags.

#### Scenario: Missing platform archive

- **WHEN** any of the four archives or the checksum file is absent
- **THEN** the release is not marked complete

### Requirement: Single owner for image tags

Exactly ONE workflow SHALL own dashboard/cli `:<ver>` image tags on a tag push, preserving the refuse-overwrite guard. Docs-only or installer-only commits SHALL NOT trigger image or release builds.

#### Scenario: Docs-only commit

- **WHEN** a push touches only docs or the installer script
- **THEN** no image build and no release build start

### Requirement: Prerelease policy explicit

The release process SHALL define whether a versioned tag publishes as prerelease or latest, resolving today's `/releases/latest` 404.

#### Scenario: First stable tag

- **WHEN** the first non-prerelease tag publishes
- **THEN** `/releases/latest` resolves to it
