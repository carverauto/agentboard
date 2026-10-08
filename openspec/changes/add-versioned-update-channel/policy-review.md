# Approved update-channel policy

Captain decision delivered in board message 1193 on 2026-10-08 approves all three recommendations below as written. This record preserves the choices and their alternatives. The change remains design-only; it authorizes completion and publication of planning, not runtime implementation.

## Approved decisions

1. **Manifest authority:** recommend GitHub release-attached, version-pinned manifest/assets. Board API caches validated status; no farm01 static host dependency. Alternative: a separately operated static authority/mirror (adds publishing, retention and trust obligations).
2. **Independent skills:** recommend a release-attached skills tar.gz, its archive SHA-256, independent semver, and the existing canonical installed-bundle digest. Preserve offline embedded `skills install` and owned-link/conflict handling. Alternative: upgrade embedded skills only by upgrading the CLI (simpler but no independent delivery), or an OCI/API bundle distributor (additional transport/hosting scope).
3. **Recipients:** recommend captain dashboard summary plus board notices for opted-in recent installation reporters; unknown installations remain unknown. Optional existing Mattermost delivery respects its enable flag. Alternative: broadcast to all registered agents (noise and no installed-version evidence), or notify captain only (agents lack actionable check-in reminders).

The question was recorded in messages 1094/1100; message 1193 is the canonical captain ruling. Complete design/specs/tasks, strict OpenSpec validation, portable Lavish review and native No-mistakes publication. Keep #127 untouched and independently shippable; never merge, cut tags, create releases or roll out under this planning task.

## Grounded findings

Initial inspection: `origin/main` at `171b44c` (including the #127 proposal merged as #135). Resumption fetched and rebased the preserved checkpoint onto `63c76bc`; the leased Treehouse v3.1.2 slot and original planning work are retained.

- `internal/cli/skills.go`: offline embedded installation, canonical sorted path/NUL/content/NUL SHA-256, verified content-addressed bundles, owned symlinks, preflight conflicts, installation lock. There is no independent remote skills updater.
- `internal/cli/root.go`: version is still constant `0.1.0`; update commands are absent.
- `.github/workflows/release.yml` and `scripts/publish-release`: manual draft publication pinned to `v0.1.0`; #127 separately owns the tag-triggered release/installer replacement.
- `docker-compose.yml`: runtime requires certificate script/initdb files plus application/database build contexts. A standalone Compose YAML cannot satisfy the no-clone path. Complete support-file packaging, published image digests/platform coverage and registry access requirements must be designed.
- `web/lib/agentboard/application.ex`: existing independent AshOban queues and feature gates provide the pattern; no new singleton query/poll broker is needed.
- `web/lib/agentboard/delivery/github_http.ex`: existing bounded read-only provider admission transport rejects redirects and uses a configured GitHub token; release-asset download transport must address GitHub's asset redirects separately and must not forward credentials to asset hosts.
- `add-release-pipeline-and-installer`: #127 is independently shippable. #57 must consume its semver/platform assets and ownership/consent contract, without rewriting its planning or making it depend on this work.

## Validation completed

Archify source `docs/architecture/versioned-update-channel.architecture.json` delivered atomically to `docs/architecture/versioned-update-channel.html`: 9/9 showcase checks, zero errors/warnings. Automated browser measurements passed at 1440×900, 1600×1000, 1920×1080 and 2048×1320. Both endpoint themes were separately inspected through their actual screenshots; receipt and screenshots are retained. This proves diagram output, not runtime update behavior.

These checks describe the original checkpoint only. Final artifact receipts and publication/CI evidence are reported separately after design completion.
