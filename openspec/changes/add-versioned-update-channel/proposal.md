# Proposal

## Why

Agents and operators install Agentboard once, then lose visibility into CLI and workflow changes. A versioned update channel will make drift actionable without interrupting active work, and extend the separate installer/release proposal into a deployment path that needs no repository checkout.

## What Changes

- Publish a bounded, versioned `update-manifest.json` alongside immutable release assets. Track CLI semver/build identity, independently versioned skills and their canonical content digest, compatibility requirements, checksums, release notes, and an optional complete Compose bundle.
- Add read-only `agentboard update check` and `agentboard skills outdated`, with explicit component results and freshness. Add consent-based `update apply` and `skills upgrade`, preserving managed-file ownership, offline skill installation, and existing command exit-code conventions.
- Add a dedicated Ash domain, audited resources and AshOban observer for release snapshots, opted-in installation reports and durable notification receipts. Expose cached status through the Phoenix API and dashboard; use the board inbox as the durable agent signal and existing Mattermost delivery only when enabled.
- Package Compose together with every runtime support file, pinned application/database images and a non-secret environment template. Download/stage it explicitly; start services only through the operator's subsequent `docker compose up`.
- Split implementation into four cohesive PRs: manifest contract/packaging; local update commands; Ash observer/API/notifications/dashboard; no-clone Compose distribution and onboarding.

This PR is **planning only**. It does not implement an updater, change authentication, start jobs, install routines, cut releases, merge or deploy. No breaking change to existing board APIs or offline `skills install` is proposed. Updates never silently replace utilities, restart agents, alter leases, modify third-party skills/hooks, or roll Kubernetes images.

## Capabilities

### New Capabilities

- `artifact-update-channel`: trusted release catalog, independent artifact identities, explicit local update lifecycle, durable drift reporting and bounded notifications, and complete versioned Compose distribution.

### Modified Capabilities

None. There are no canonical specs in `openspec/specs/` at the inspected baseline. The in-flight `add-release-pipeline-and-installer` change owns `release-pipeline` and `cli-installer`; this change consumes its output without rewriting those capabilities or making #127 depend on #57.

## Impact

- Planning source: [GH #57](https://github.com/carverauto/agentboard/issues/57); prerequisite contract: [GH #127](https://github.com/carverauto/agentboard/issues/127) and `add-release-pipeline-and-installer`.
- Expected implementation areas: `.github/workflows/release.yml`, `scripts/publish-release`, `build/release/`, embedded skills packaging, `internal/cli/`, `internal/client/`, new `web/lib/agentboard/updates/` resources/domain, runtime queue configuration, Phoenix routes/LiveView, Compose packaging, and generic setup/release docs.
- Additive PostgreSQL migrations require a schema ordinal allocated against current main at implementation time; this proposal reserves none. CLI board writes remain API-only; no singleton GenServer broker serializes SQL or provider requests.
- Suggested defaults awaiting design review: GitHub release assets as the authority; a separate skills archive with existing canonical digest; opted-in installation recipients rather than broadcasting to every registered agent. Coordinator policy question is board message 1094. These are review recommendations, not an authorization to implement them.
- Review material: `docs/architecture/versioned-update-channel.html` and a portable Lavish rendering of this change. Maintainer-specific rollout remains separately authorized work.
