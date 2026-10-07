# #58 checkpoint — work in progress

This is an unpublished WIP checkpoint, not a passing acceptance or publication receipt. The source branch starts at main `76918e8`. No deployment, flag changes, PR, push or merge was performed.

## Remote verification

All compilation/tests used remote `./scripts/bazel --config=remote`; nothing was compiled on the workstation.

[Current five-target BuildBuddy run](https://carverauto.buildbuddy.io/invocation/3c8c1279-59f5-4e55-ba72-c6c73b6f2b02) completed with four passing targets:

- `//build/integration:ci_accountability_test`
- `//build/integration:delivery_github_test`
- `//build/integration:delivery_polling_test`
- `//build/integration:delivery_scheduling_test`

`//build/integration:merge_disposition_test` fails in fixture setup for disabled-polling catch-up: it writes `delivery_pull_requests.enabled`, which does not exist. The real field is `delivery_poll_states.enabled`. Correct that fixture after the requested session restart, then rerun. Earlier runs reached the actual configured minute job, source Review→Done, lease clearing/assignee preservation, PaperTrail/AshEvents/timeline proof, disabled action, old evidence/expired ownership, unchanged failing-CI repair, relink/open/closed/cleared/mismatched proof fences and audit rollback. These partial executions do not establish that the complete suite passes. The new all-submission fence reached open/closed rejection before the setup error; its successful terminal catch-up, notification-count correction and >100-record continuation still need completed proof.

## Documentation

OpenSpec strict validation passed for `adopt-ash-and-monitor-pr-ci`. Archify deterministic delivery passed 9/9 showcase with zero errors/warnings, bound by [the receipt](../architecture/pr-merge-disposition.receipt.json). Its automated browser inspection **failed** because Chrome terminated with SIGABRT; the artifact was not changed to bypass that environment failure. Perceptual review is pending: local review-page browser access was denied. [The portable Lavish policy](../architecture/pr-merge-disposition-openspec.html) uses the application's existing light/dark tokens and has no external dependencies.

## Remaining before delivery

1. Correct the disabled-polling fixture field and finish packaged integration proof; run a pre-fix negative control demonstrating Review stays uncleared.
2. Add the coordinator's latest explicit owner inbox notification requirement, atomically with completion (existing Mattermost compatible-update capture is present), and prove once-only delivery plus rollback. Do not claim agent wakeup from mere message capture.
3. Finish remote source formatting and scoped code review. Check fresh main merges cleanly without altering the retained pruning worktree.
4. Complete truthful browser/perceptual evidence when a permitted capable surface is available, update/export the proposal and upload task-bound HTML documents.
5. Deliver a checksum-bound portable patch and native No-mistakes publication after access is restored. No --yes, direct publication bypass or merge. Keep the parent OpenSpec checklist incomplete until its full acceptance is met.

The separate prepared pruning worktree and both task leases are retained for the coordinator-requested restart. No active No-mistakes run exists for this WIP.
