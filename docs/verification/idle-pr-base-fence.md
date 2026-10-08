# Idle PR observation after base movement

Issue [#102](https://github.com/carverauto/agentboard/issues/102) corrects the
collection fence introduced in #94. An idle GitHub PR can retain an older
`pull.base.sha` after its base branch advances. Comparing that field to the
current branch tip silently rejected otherwise valid polls.

The reservation now captures branch-watch revision and head before external
requests. Commit locks the applicable watch before the PR poll row, in the same
order as invalidation, and rejects only a watch change during collection.
Snapshots retain the original provider `base_sha` and record `base_watch_sha`
in their existing payload; freshness uses that binding. Older snapshots keep
the historical fallback until refreshed. Terminal PR polling remains
metadata-only. No database migration or deployment flag change is required.

A changed watch records `base_changed` and a 60-second retry while the attempt
is still current. If branch invalidation supersedes the attempt first, it
records the error and schedules the new generation without overwriting a newer
reservation. Snapshot, projection, audit and accountability writes remain
transactional. External HTTP requests run outside row locks.

## Remote regression proof

The changed canonical integration test first failed against unchanged production
code at “Idle PR was rejected because payload base.sha lagged the branch tip”:
[baseline invocation](https://carverauto.buildbuddy.io/invocation/57fa5b7d-3e3d-4974-8a2f-ec731803eb5d).
It passed with the repair:
[regression invocation](https://carverauto.buildbuddy.io/invocation/e6cead5f-4ba6-4604-879c-936e4e6dd0c0).

After applying remote formatter output, all seven relevant integration suites
passed in the [final invocation](https://carverauto.buildbuddy.io/invocation/ec684fce-23be-4e86-9fbb-87f626cfcda8):

```sh
./scripts/bazel test \
  //build/integration:pr_conflicts_test \
  //build/integration:delivery_github_test \
  //build/integration:delivery_polling_test \
  //build/integration:delivery_scheduling_test \
  //build/integration:ci_accountability_test \
  //build/integration:merge_disposition_test \
  //build/integration:release_schema_test --test_output=errors
```

The regression exercises the packaged release, API and persistent state against
a deterministic HTTPS GitHub fixture. It checks idle-PR snapshot admission,
provider/base-watch attribution, freshness, due-time advancement, and a branch
move during blocked HTTP collection before invalidation reaches the PR. The
latter produces no snapshot, records an error, releases the attempt and advances
the retry. Existing conflict, terminal, pagination and audit rollback cases
remain in the suite. No tests or builds ran locally on the workstation. No
production database writes, rollout or flag changes were performed.

The Ripwire quality delta flags historical short-horizon churn in `Polling`
(six rewrites of touched lines), minor module/function growth, and generated
browser-receipt verbosity. The focused concurrency correction intentionally
keeps the existing transactional owner rather than mixing an unrelated module
refactor into this regression fix. This is a documented tradeoff, not a clean
quality-delta verdict.

## Architecture evidence

Source: [workflow JSON](../architecture/idle-pr-base-fence.workflow.json).
Portable viewer: [Archify HTML](../architecture/idle-pr-base-fence.html).
Artifact SHA-256:
`563c6ff325c7eb0fd9c46df88e4f9e95e5a388bfa03c3f7dd1b9a58eea8d9bf5`.

Deterministic validation passed 9/9 showcase checks with zero errors or warnings.
Automated browser checks passed containment, readability and viewer chrome at
1440, 1600, 1920 and 2048 pixel desktop widths. The retained
[browser receipt](../architecture/idle-pr-base-fence.visual-check.json) and
[contact sheet](../architecture/idle-pr-base-fence.visual-check.html) bind that
evidence to the artifact. Perceptual inspection of the 1440 light and 2048 dark
captures found readable labels, clear success/retry routing and no overlaps.
These are documentation browser checks; they do not establish live farm01
polling recovery. Captain rollout and live observation remain separate steps.
