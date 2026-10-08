# Policy review required before completing design

This is a preserved planning checkpoint for GH #57, not an approved design or implementation-ready change. The initial proposal and Archify diagram are review material. Design, normative requirements and implementation tasks are deliberately pending coordinator policy resolution; no runtime/source code has changed.

## Decisions requested

1. **Manifest authority:** recommend GitHub release-attached, version-pinned manifest/assets. Board API caches validated status; no farm01 static host dependency. Alternative: a separately operated static authority/mirror (adds publishing, retention and trust obligations).
2. **Independent skills:** recommend a release-attached skills tar.gz, its archive SHA-256, independent semver, and the existing canonical installed-bundle digest. Preserve offline embedded `skills install` and owned-link/conflict handling. Alternative: upgrade embedded skills only by upgrading the CLI (simpler but no independent delivery), or an OCI/API bundle distributor (additional transport/hosting scope).
3. **Recipients:** recommend captain dashboard summary plus board notices for opted-in recent installation reporters; unknown installations remain unknown. Optional existing Mattermost delivery respects its enable flag. Alternative: broadcast to all registered agents (noise and no installed-version evidence), or notify captain only (agents lack actionable check-in reminders).

Board message 1094 asks the configured coordinator for the captain's ruling. Implementation must not silently promote a recommendation into a decision. After the answer: record it here, update proposal/diagram if necessary, then create design/specs/tasks through the OpenSpec artifact workflow. Complete portable Lavish review and native No-mistakes publication before reporting design delivery.

## Grounded findings

Baseline: freshly fetched `origin/main` commit `9a34363` in a leased Treehouse v3.1.2 slot.

- `internal/cli/skills.go`: offline embedded installation, canonical sorted path/NUL/content/NUL SHA-256, verified content-addressed bundles, owned symlinks, preflight conflicts, installation lock. There is no independent remote skills updater.
- `internal/cli/root.go`: version is still constant `0.1.0`; update commands are absent.
- `.github/workflows/release.yml` and `scripts/publish-release`: manual draft publication pinned to `v0.1.0`; #127 separately owns the tag-triggered release/installer replacement.
- `docker-compose.yml`: runtime requires certificate script/initdb files plus application/database build contexts. A standalone Compose YAML cannot satisfy the no-clone path. Complete support-file packaging, published image digests/platform coverage and registry access requirements must be designed.
- `web/lib/agentboard/application.ex`: existing independent AshOban queues and feature gates provide the pattern; no new singleton query/poll broker is needed.
- `web/lib/agentboard/delivery/github_http.ex`: existing bounded read-only provider admission transport rejects redirects and uses a configured GitHub token; release-asset download transport must address GitHub's asset redirects separately and must not forward credentials to asset hosts.
- `add-release-pipeline-and-installer`: #127 is independently shippable. #57 must consume its semver/platform assets and ownership/consent contract, without rewriting its planning or making it depend on this work.

## Validation completed

Archify source `docs/architecture/versioned-update-channel.architecture.json` delivered atomically to `docs/architecture/versioned-update-channel.html`: 9/9 showcase checks, zero errors/warnings. Automated browser measurements passed at 1440×900, 1600×1000, 1920×1080 and 2048×1320. Both endpoint themes were separately inspected through their actual screenshots; receipt and screenshots are retained. This proves diagram output, not runtime update behavior.

No local builds, remote runtime tests, release creation, deployment, native publication, or implementation has occurred at this checkpoint.
