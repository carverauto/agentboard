# Proposal

## Why

Agents currently deliver PRs and move on without confirming CI finishes successfully. The board stores a PR URL but cannot show failing jobs, explain failures, or retain a visible follow-up obligation. The application also needs to adopt the requested Ash framework conventions before adding background automation.

## What Changes

- Make Ash resources/domains and AshPostgres the board's application boundary for API, LiveView, documents, quota and worker operations. Retain existing PostgreSQL data, API v1 contracts, explicit leases, atomic claims and immutable history.
- Add AshPaperTrail resource versions and attributed AshEvents action records, with scoped locking rather than a shared write bottleneck. Preserve the existing public task timeline as a compatible projection.
- Add an AshOban PR-monitor job that discovers every board-linked GitHub PR, checks its current head and applicable CI policy, and stores bounded, retry-safe observations.
- Observe GitHub mergeability independently of CI; recheck every observed open PR after its base branch moves within the shared provider budget. With cooperation enabled, retain one rebase follow-up per conflicting head and notify the responsible owner without claiming work or changing source tasks.
- Add a dashboard PR table with CI state, failed checks, repository/head, responsible agent, observation freshness, GitHub/BuildBuddy evidence and outstanding follow-up.
- Collect failed check/job details from GitHub and correlated invocation/log evidence through the BuildBuddy API. Keep GitHub and BuildBuddy credentials in namespace Secrets and never expose them to the CLI or HTML.
- Keep failed/pending/unknown/stale CI visibly distinct from green. Prevent owner-requested linked-PR deliveries from becoming done until current-head CI is verified; preserve existing terminal tasks and create a deduplicated board follow-up for failures discovered afterward.
- Add explicit merged-Review disposition: a system AshOban catch-up completes source Review tasks only when their current PR and all retained submissions have matching immutable merged evidence. Preserve the assignee, append merge proof, clear the lease and retain repair-task history; terminal PRs close the machine obligation with an audited lifecycle reason, preserving CI qualification; terminal polling may stop without losing this catch-up.
- Update the canonical and captain skills: PR delivery includes waiting for CI, inspecting failures, fixing and rechecking, or explicitly recording a blocker/handoff. The monitor observes and records; it does not launch coding agents, merge PRs or sweep expired claims.

## Capabilities

### New Capabilities

- `ash-application`: Shared Ash resource/action/domain boundary, attributed version/event history, migration compatibility and independent request/job concurrency.
- `pr-ci-monitoring`: Durable current-head CI monitoring, provider evidence, bounded retries and visible follow-up accountability.
- `pr-ci-dashboard`: Read-only PR status table and failure/evidence detail linked to board tasks.
- `ci-delivery-workflow`: CI-aware delivery gate and agent/captain follow-up requirements.

### Modified Capabilities

None in the main specification inventory yet (`openspec list --specs` reports none). The two completed changes remain the baseline for existing task/dashboard/workflow behavior; this change adds CI obligations and explicitly preserves those contracts rather than silently rewriting their unarchived artifacts.

## Impact

`web/mix.exs`, the hermetic Hex dependency closure and remote release checks; `web/lib/agentboard/{board,documents,quota}.ex`; API/watch/document controllers and LiveView; additive migrations and existing database functions; farm01 runtime Secrets/configuration and worker supervision; API/CLI CI reads and task completion errors; shared skills and release/verification documentation. New dependencies are Ash, AshPostgres, AshPhoenix, AshPaperTrail, AshEvents, Oban and AshOban, plus a pinned HTTP client selected during remote dependency resolution. No new message broker or object store is required. Implementation will be staged under this one proposal; the current v0.1.0 service remains live during planning.
