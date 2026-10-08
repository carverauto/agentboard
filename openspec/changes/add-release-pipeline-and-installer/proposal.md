# Proposal

## Why

Every seat hand-installs the agentboard CLI today (download, verify, PATH, skills install by hand), and releases are cut against hardcoded `v0.1.0` pins (`internal/cli/root.go` constant, `release.yml`, `scripts/publish-release`, `build/release:cli_artifacts`). A ripwire-style one-line installer plus a tag-triggered release pipeline removes that toil and makes CLI/skills rollout repeatable — the prerequisite for fleet-wide skill delivery (#119 slice 1) and the versioned update channel (#57).

## What Changes

- Phase 1: a tag-triggered release pipeline. On `v*.*.*` tag pushes (plus `workflow_dispatch` re-run): remove the `v0.1.0` pins; gate on tag-on-main, green `//:acceptance` on BuildBuddy, and CLI version equal to the tag (prefer `x_defs` stamping over today's constant); cross-compile darwin/linux × arm64/amd64 on BuildBuddy remote (`--config=ci` on arc-runner-set); package `agentboard-<ver>-<os>-<arch>.tar.gz` plus `SHA256SUMS`; `gh release create` with notes; pick the prerelease-vs-latest policy (`/releases/latest` 404s today); make ONE workflow own dashboard/cli `:<ver>` image tags (today `images.yml` and `release.yml` both push `dashboard:<tag>` on tag push; keep the refuse-overwrite guard); attestations/cosign optional; semver, captain cuts tags only; docs-only/installer-only commits never trigger image or release builds.
- Phase 2: `scripts/install.sh` modeled on ripwire's installer — platform detection; resolve latest or `AGENTBOARD_VERSION`; mandatory `SHA256SUMS` check, archive path safety, binary version check; atomic rename into `~/.local/bin` with PATH hint, no rc edits; `-y/--yes` or `AGENTBOARD_YES=1` non-interactive (confirmation from `/dev/tty`); idempotent upgrade plus `--uninstall`; skills via the installed binary's `agentboard skills install --dir` only for present harnesses with verified discovery dirs (verify Hermes/Pi/Grok/Cursor/Muse paths or print manual lines); no hooks by default; env hints without writing config or secrets; `launch-seat` provisions/validates the pinned CLI for new seats; hermetic `sh_test`; cross-references #57 (update manifest, not a prerequisite) and #60.
- Tasks run Phase 1 before Phase 2.
- No implementation until the captain approves this proposal in Lavish.

## Capabilities

### New Capabilities

- `release-pipeline`: tag-triggered, gated CLI release builds with packaged artifacts and notes.
- `cli-installer`: one-line verified install, upgrade, and uninstall of the CLI plus skills wiring.

### Modified Capabilities

None. Existing release/images workflows are superseded in behavior defined entirely inside `release-pipeline`; no current spec requirements change.

## Impact

- `.github/workflows/release.yml`, `scripts/publish-release`, `build/release/BUILD.bazel` (unpin versions, gate, package).
- ONE workflow owns image tags; `images.yml` ignores docs/installer-only paths including `scripts/install.sh`.
- New `scripts/install.sh` + hermetic test; `launch-seat` validates the pinned CLI version.
- `internal/cli/root.go` version constant gives way to build stamping (preferred) — Semver source of truth moves from code to tag.
