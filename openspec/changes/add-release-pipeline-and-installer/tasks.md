# Tasks

## 1. Phase 1: release pipeline (first)

- [ ] 1.1 Remove the `v0.1.0` pins in `.github/workflows/release.yml`, `scripts/publish-release`, and `build/release:cli_artifacts`; verify no `0.1.0` literal remains in the release path.
- [ ] 1.2 Stamp the CLI version from the tag (preferred: `x_defs`) and gate the pipeline on tag-on-main, green `//:acceptance`, and version-equals-tag; verify each refusal path on a scratch tag.
- [ ] 1.3 Cross-compile darwin/linux × arm64/amd64 on BuildBuddy remote and package `agentboard-<ver>-<os>-<arch>.tar.gz` plus `SHA256SUMS`; verify all four archives plus checksums on a prerelease tag.
- [ ] 1.4 Publish with `gh release create` and notes under the approved prerelease-vs-latest policy; verify `/releases/latest` behavior matches the policy.
- [ ] 1.5 Consolidate image-tag ownership into ONE workflow (keep refuse-overwrite) and ignore docs-only/installer-only paths; verify a docs-only push triggers neither build.

## 2. Phase 2: installer (after Phase 1)

- [ ] 2.1 Author `scripts/install.sh` (platform detect, version resolve, checksum + path-safety + version checks, atomic rename to `~/.local/bin`, PATH hint, `/dev/tty` confirm, idempotent upgrade, `--uninstall`, skills for verified harnesses only, env hints); verify each behavior in a sandbox.
- [ ] 2.2 Add the hermetic `sh_test` covering checksum failure, version mismatch, idempotent upgrade, and uninstall; verify it passes with no network or host mutation.
- [ ] 2.3 Wire `launch-seat` to validate the pinned CLI version for new seats; verify a drifted seat fails loudly.
- [ ] 2.4 Cross-reference #57 (manifest) and #60 without making either a prerequisite; verify links resolve.

## 3. Closeout

- [ ] 3.1 Record CI status on the card and link the implementing PRs; verify links resolve.
