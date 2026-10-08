# Design

## Context

See proposal.md (Why). Current state: `Version = "0.1.0"` constant in `internal/cli/root.go`; `v0.1.0` pinned in `release.yml`, `scripts/publish-release`, and `build/release:cli_artifacts`; `images.yml` and `release.yml` both push `dashboard:<tag>` on tag pushes; no installer script exists. Reference model: ripwire's `scripts/install.sh`.

## Goals / Non-Goals

Goals: one-command verified install; gated reproducible releases; single image-tag owner; no local builds anywhere in the path. Non-goals: changing the CLI's behavior (only its version source); the update manifest itself (#57, cross-referenced not prerequisite); attestations/cosign beyond optional.

## Decisions

- **`x_defs` stamping for the CLI version** over bumping the constant: the tag becomes the single source of truth; a mismatch gate compares stamped version to tag. Alternative (release-commit bump) rejected — extra commits per release, drift-prone.
- **BuildBuddy remote (`--config=ci`, arc-runner-set) for all four platform pairs** over local cross-compile: matches the repo's remote-only rule; credentials already in the `agentboard-release` environment.
- **ONE workflow owns image tags; ignore-lists exclude docs/installer paths** over splitting workflows per path: keeps the refuse-overwrite guard in one place; `scripts/install.sh` joins the `images.yml` ignore list.
- **Installer modeled line-by-line on ripwire's script** over bespoke design: proven shape (platform detect, checksum, atomic rename, `/dev/tty` confirm, uninstall); adapted only for skills wiring and env hints.
- **Skills via installed binary, verified dirs only** over direct file copies: the binary owns the layout contract; unverified paths get printed instructions, never writes.
- **`launch-seat` validates (not installs) the pinned CLI** over silent auto-install: seats fail loudly on version drift rather than mutating the host mid-launch. Install remains the operator's explicit act.
- **No schema changes, no migrations**: release metadata lives in GitHub releases and workflow artifacts.

## Risks / Trade-offs

- [First real tag exercises untried paths] → `workflow_dispatch` re-run plus report-only dry window before the first stable tag; prerelease tags first.
- [`/releases/latest` behavior change] → Policy decision is explicit in the proposal (prerelease vs latest); implement exactly what the captain approves.
- [Installer curl-pipe trust] → Mandatory checksum + version check make a tampered archive fail closed; no secrets ever flow through the script.
- [Four-platform matrix time] → Remote execution absorbs it; artifacts publish only when all four land.

## Migration Plan

Additive: new workflow behavior gates on tags (existing flows untouched until the first tag); installer is a new file. Rollback: delete the tag (before stable), revert the workflow, remove the script. No data migration.

## Open Questions

None blocking. Prerelease-vs-latest default and cosign scope are captain decisions inside the stated bounds.
