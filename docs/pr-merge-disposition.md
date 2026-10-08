# Merged PR disposition

With `AGENTBOARD_PR_OBSERVATION_ENABLED=true`, the server's minute AshOban catch-up moves eligible source cards from **Review → Done**. It uses retained merge observations, including after terminal polling stops or downtime. No LLM, coding-agent wakeup, provider request, reclaim or lease renewal is involved.

Eligibility requires Review, a current canonical GitHub PR, and matching immutable merged evidence for that PR and **all retained submissions** (up to 100 per task). Open, closed-unmerged, unknown or mismatched submissions block completion. Cleared links, PRs mentioned only in notes, other statuses and CI repair tasks are preserved. `/prs` exposes lifecycle/evidence; owners and the captain explicitly handle exceptions. The watcher preserves the assignee even after lease expiry, clears the completed task's lease and records `ci-accountability` system provenance through `Task.complete_merged_pr`.

**Done from merged lifecycle does not mean green CI.** Unknown/failing/stale CI remains unchanged, and failure obligations and their repair tasks remain actionable. Agents must still investigate CI failures and explicitly report blockers/handoffs. Owner-requested completion retains its ordinary ownership rules; the proposed fresh-green guard remains separate.

The same Board transaction appends PaperTrail, AshEvents and an `update` timeline event with `merge_evidence`: policy `merged_review_v1`, canonical URL, snapshot/generation/head/base/observed time/CI state, and proof for every submission. An assigned owner receives one durable inbox message in the same transaction; enabled Mattermost/cooperation intents commit with it. When the task records a launch-seat slot (`agentboard-seat …` update), the message also carries the slot-return instruction (same-version `treehouse return`, never `--force`); tasks without a slot record get the plain completion message. The timestamp is when the provider was observed merged, not an invented GitHub merge time. Audit/capture failure leaves state and lease intact; replay/concurrent workers create one completion.

Catch-up scans 100 Review records per page and persists continuation jobs. It locks the task before PR states in sorted ID order. Disabled queued actions snooze. There is no schema migration or new configuration flag. Turning observation off stops automatic disposition; rolling back preserves completed history rather than reopening tasks.

## Retained-evidence backfill

The scheduled action already backfills eligible cards from retained merged snapshots even if their PR polling is disabled. An authorized operator can invoke the same system action for immediate catch-up on the running release:

```elixir
Ash.ActionInput.for_action(Agentboard.Delivery.MergeDisposition, :reconcile, %{},
  actor: %{role: :system})
|> Ash.run_action()
```

Run through the deployment's private operator release/RPC interface, never the public task API. If a PR was stopped before trustworthy merged evidence was collected, do not fabricate a snapshot or edit lifecycle columns. Deliberately refresh that PR through the existing provider collector under authorized polling configuration. Cards with no PR URL require explicit owner/captain handling.

See [Archify workflow](architecture/pr-merge-disposition.html), [OpenSpec policy](../openspec/changes/adopt-ash-and-monitor-pr-ci/specs/ci-delivery-workflow/spec.md), [portable proposal](architecture/pr-merge-disposition-openspec.html) and [verification receipt](verification/pr-merge-disposition.md).
