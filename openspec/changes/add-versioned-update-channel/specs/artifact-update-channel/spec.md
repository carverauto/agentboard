# Spec Delta

## Purpose

Give operators and agents trustworthy, actionable visibility into CLI and skill drift, with explicit local upgrades and a complete release-pinned Compose bootstrap path that preserves existing work and data.

## ADDED Requirements

### Requirement: Release-pinned authoritative catalog
The system SHALL consume a supported versioned manifest from the configured GitHub repository's immutable published release. The board SHALL expose only validated cached status and provenance. Stable selection SHALL exclude drafts/prereleases and SHALL NOT silently downgrade an accepted component or reinterpret a published version with changed identity.

#### Scenario: Published eligible release
- **WHEN** complete bounded release enumeration identifies a higher eligible stable SemVer with matching manifest, source and asset identities
- **THEN** the catalog records those verified component identities and exact release provenance

#### Scenario: Missing or changed authority
- **WHEN** no eligible release exists, enumeration is incomplete, the release is mutable, or an existing version's digest changes
- **THEN** the result identifies unavailability/incompleteness/conflict, retains the last validated snapshot and does not advertise a fresh update

### Requirement: Independent artifact identities
The manifest SHALL identify CLI SemVer/build/binary and archive digests, independently versioned skills with archive and canonical installed-tree digests, compatibility requirements and supported platforms. Unchanged skills SHALL retain their identity across CLI releases; changed skill payloads SHALL receive a new version. Hash validation SHALL NOT be described as independent publisher authentication.

#### Scenario: CLI-only release
- **WHEN** a release advances CLI identity while retaining the installed verified skills version/digest
- **THEN** the comparison reports the CLI update separately and reports those skills as current

#### Scenario: Distinct skills hashes
- **WHEN** an archive checksum matches but its extracted tree differs from the advertised canonical installed-bundle digest
- **THEN** skill installation refuses without changing discovery links

### Requirement: Read-only update checks
`update check` and `skills outdated` SHALL compare actual local identities and receipts with the selected catalog without installation, enrollment or board mutation. Results SHALL expose per-component state, compatibility, source/freshness and next action in human and versioned JSON output. Update availability SHALL return exit 0; existing error-code conventions SHALL remain intact.

#### Scenario: Outdated installed component
- **WHEN** a read-only check finds a newer compatible component with fresh validated catalog evidence
- **THEN** it reports `update_available`, installed/target identities and explicit next action, exits successfully and changes no binary, skill link, report or notice

#### Scenario: Unknown, ahead or stale install
- **WHEN** an installation lacks provable identity, is newer than the selected target, or catalog evidence is stale/unavailable
- **THEN** it reports `unknown`, `ahead` or the explicit freshness failure rather than claiming it is current

### Requirement: Explicit compatible local updates
Updates SHALL target an exact version and one named component, require controlling-TTY consent or explicit unattended confirmation, and verify provenance/hashes/compatibility before replacing managed content. Declined consent, unsupported platform, incompatible updater/board or downgrade SHALL preserve the original installation. Checks SHALL never imply consent or migrate the board.

#### Scenario: Unattended refusal
- **WHEN** `update apply` has no controlling TTY and no explicit confirmation
- **THEN** it refuses before replacing anything and explains how to confirm the exact operation

#### Scenario: Compatible CLI update
- **WHEN** the approved exact CLI release is compatible and its archive/binary/version are verified against a managed destination and current fingerprint
- **THEN** it atomically replaces that destination, records the installed identity and retains verified recovery material without restarting a harness or changing claims

#### Scenario: Compatibility refusal
- **WHEN** the target requires a newer updater, unsupported platform/API range or higher board schema floor
- **THEN** apply identifies the unmet requirement and changes no installed component or database schema

### Requirement: Managed skill ownership and interruption recovery
Offline embedded `skills install` SHALL remain available. Remote upgrade SHALL preserve the existing verified bundle/owned-link contract and retain old bundles. Foreign or edited content SHALL cause refusal. Interrupted per-link changes SHALL be recorded truthfully and recovered only after revalidating matching owned destinations; all-directory atomicity SHALL NOT be claimed.

#### Scenario: Foreign or edited skills
- **WHEN** a chosen discovery destination is foreign, an old bundle is edited or a link changes during staging
- **THEN** upgrade refuses that overwrite, preserves user content and reports the conflict and any already-committed owned-link changes

#### Scenario: Interrupted switch
- **WHEN** a process stops after some owned links advance
- **THEN** recovery can identify their exact prior/new identities, revalidate them and explicitly complete or restore matching links without overwriting intervening manual changes

#### Scenario: Existing agent session
- **WHEN** new skill files have been installed
- **THEN** output instructs the agent to re-read the changed workflow and does not claim model context, routines or wake hooks refreshed automatically

### Requirement: Bounded trusted download transport
Metadata and downloads SHALL have byte/extraction limits, deadlines, cancellation and bounded retry/redirect handling. Every destination SHALL satisfy configured HTTPS/public-origin rules. Board credentials SHALL never be sent to release hosts; API credentials SHALL NOT follow a cross-host asset redirect. Rate limits SHALL retain provider retry floors within bounded operation time.

#### Scenario: Malicious archive or redirect
- **WHEN** a response exceeds limits, resolves to a private endpoint, redirects outside approved hosts, or an archive contains traversal, links, special files or duplicate paths
- **THEN** the operation refuses, preserves original installed content and emits a safe typed error without secret/raw-body output

#### Scenario: Throttled provider
- **WHEN** a 429 or GitHub secondary limit requests a delay beyond the command's deadline
- **THEN** the command returns a retry time instead of spinning or silently ignoring the provider floor

### Requirement: Durable independent release observation
Board observation SHALL be independently enabled, bounded and durable across replicas/restarts. It SHALL retain last-known-good snapshots on errors, reject stale-worker commits and show fresh/stale/unavailable observation state. Provider outages SHALL NOT block board readiness, CI work or pooled concurrent requests. HTTP SHALL occur outside ownership/budget transactions.

#### Scenario: Concurrent or crashed observers
- **WHEN** two replicas race or an admitted observer dies and a later worker recovers its lease
- **THEN** only the current fenced observation can commit; old results cannot overwrite newer state and the board continues serving

#### Scenario: Observation independent of PR flag
- **WHEN** updates are enabled while PR observation is disabled
- **THEN** release observation can proceed under its own gate while sharing the configured GitHub credential budget, and no PR queue is unpaused

#### Scenario: Invalid provider response
- **WHEN** fetch is malformed/oversized/unauthorized, or a 304 has no matching validated cached representation
- **THEN** error/freshness metadata is recorded, previous valid bytes remain visible and no fresh target or notification is created from the failure

### Requirement: Explicit attributed installation reports
Installations SHALL report only through an explicit API operation, with random local installation identity, component identities, channel, report sequence/idempotency key and notification consent. Reports SHALL contain no secrets, host paths or repo inventory. Newer reports SHALL win; identical retries SHALL be idempotent and changed reuse SHALL conflict. Evidence SHALL be labeled self-reported under existing auth policy.

#### Scenario: Multiple seats for one agent
- **WHEN** one agent reports two installations with different versions
- **THEN** both installations remain distinguishable without one overwriting the other or exposing workstation paths

#### Scenario: Delayed or conflicting report
- **WHEN** an old sequence arrives after a newer report or the same idempotency key is reused with changed content
- **THEN** it cannot replace newer identity/consent and reports stale sequence or conflict

#### Scenario: Verified principal mismatch
- **WHEN** a report's declared agent conflicts with the verified principal under the existing principal-mismatch policy
- **THEN** the existing guard applies without #57 weakening it or turning on auth enforcement

### Requirement: Opt-in bounded agent signals
Captain summary SHALL show catalog freshness and reported drift. Agent notices SHALL require explicit opt-in, recent installation evidence and a valid compatible target mismatch. Unknown installs SHALL receive no notices. The board SHALL durably deduplicate each recipient/component/target identity across installs, retries and replicas, coalesce pending releases and cap summaries at one per recipient/day.

#### Scenario: Late report and repeated job
- **WHEN** an opted-in recent report arrives after release discovery and multiple reconciliation attempts process it
- **THEN** it produces at most one durable inbox notice for that recipient/component/target identity with a concrete check/apply action

#### Scenario: Unknown or withdrawn installation
- **WHEN** no verified report exists, its report is older than seven days, or the recipient turns consent off
- **THEN** no new agent notice is sent; unsent withdrawn intents are cancelled and delivered history remains

#### Scenario: Mattermost outage or disabled bridge
- **WHEN** chat routing is disabled or Mattermost is unavailable
- **THEN** the committed board notice remains accessible, chat failures do not affect core work, and no bridge or Herdr wake adapter is enabled automatically

### Requirement: Honest dashboard status
The dashboard SHALL show available/installed component identities, installation recency, catalog/error time, compatibility and unknown/stale/conflict states with actionable next steps. It SHALL preserve the existing Kanban and theme. The summary SHALL NOT infer that every registered agent reported an installation, that skills were re-read, or that CI responsibilities were discharged.

#### Scenario: Self-reported stale seat
- **WHEN** a seat has an outdated report and fresh target information
- **THEN** its row identifies stale self-reported evidence separately from the available release and suggests a check/report, rather than certifying current installation state

### Requirement: Complete release-pinned Compose bootstrap
A manifest SHALL advertise Compose only after the complete bundle has passed disposable Linux bootstrap proof. It SHALL include all referenced local support files, secret-free templates, image digests/platforms and registry-access prerequisites, with no build/source dependency. Fetch SHALL stage into a fresh directory only and SHALL NOT start services, modify an existing `.env`, migrate a live deployment or prune data.

#### Scenario: Clean no-clone installation
- **WHEN** an operator fetches a verified supported-platform bundle, fills its private environment and meets stated registry/Compose prerequisites
- **THEN** `docker compose up -d --wait` can start from that bundle alone, run migration and dashboard from the same image digest, and expose healthy API/meta without cloning source

#### Scenario: Existing destination or missing image
- **WHEN** the fetch destination is populated or a required image/platform/support file is unavailable
- **THEN** fetch refuses the destination overwrite or the release omits Compose advertisement; no existing environment or volume is altered

### Requirement: Additive compatibility and safe disablement
The update channel SHALL preserve prior offline CLI/skill paths and existing API behavior. New board writes SHALL negotiate a separately allocated schema floor before mutation. Disabling or rolling back observation SHALL preserve reports/snapshots/receipts and SHALL NOT lower schema markers, delete history, restart agent sessions or apply Kubernetes rollout changes.

#### Scenario: Older board and disablement
- **WHEN** an updater encounters an older board schema or an operator disables update observation
- **THEN** unsupported board writes fail safely, compatible offline operations remain available, and retained update history and ordinary task/CI work are preserved
