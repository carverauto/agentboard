## Purpose

Turn the prose rollout runbook (`docs/deploy/reference-farm01.md`) into one digest-pinned, self-verifying, self-rolling-back command with a machine-readable record matching today's `docs/verification/*-rollout.json` shape.

## ADDED Requirements

### Requirement: Digest-only image pins

`admin rollout <image@sha256:...>` SHALL accept only immutable digest pins and SHALL reject tags.

#### Scenario: Tag rejected

- **WHEN** `admin rollout` is given a tag instead of a digest
- **THEN** it exits nonzero before any backup or mutation, naming the digest requirement

### Requirement: Ordered safe rollout

The rollout SHALL execute in order: (1) pre-migration backup — CNPG on-demand `Backup` when backups are configured (#98), otherwise a logical dump to an operator-supplied path; (2) migration Job with the SAME digest as the Deployment, waited on to success; (3) roll the Deployment; (4) verify — rollout status, readiness, `agentboard meta` schema and protocol, a smoke read, and a configurable soak window; (5) on verification failure, automatic rollback to the previous pin.

#### Scenario: Rollout of the same digest twice

- **WHEN** `admin rollout` runs twice with the same digest against a converged deployment
- **THEN** the second run detects the deployed pin, performs no backup/migration/roll, and reports converged

#### Scenario: Failed verification rolls back

- **WHEN** verification fails after the Deployment rolls
- **THEN** the previous pin is restored automatically, the command exits `3`, and the rollout record marks the rollback

#### Scenario: Backup runs before migration

- **WHEN** any rollout proceeds past the backup step
- **THEN** the completed backup is recorded before the migration Job is created

### Requirement: Machine-readable rollout record

Each rollout SHALL write a record in the shape of today's `docs/verification/*-rollout.json` (image and previous pins, backup, migration, schema, verification results, rollback flag) carrying no secret values.

#### Scenario: Record without secrets

- **WHEN** the rollout record is inspected
- **THEN** it parses as JSON with the documented fields and contains no token or secret values

### Requirement: Pluggable generic targets

The rollout SHALL support Kubernetes/kustomize targets (edit the overlay's `images:`/env for GitOps, or apply directly) and docker compose targets (lined up with #57). Cluster, namespace, context, overlay path, hostnames, and Secret names SHALL all be inputs with no baked-in defaults; farm01 SHALL appear only as an example config in docs, never as a code path.

#### Scenario: Example overlay config

- **WHEN** a new team starts from `k8s/overlays/example` plus the sample admin config
- **THEN** every target field they must set is an explicit input, and no farm01 value is assumed
