# Conflict-routing foundation checkpoint

This is a partial implementation checkpoint for GH #169 and the approved
`add-server-conflict-routing` proposal. Only checklist items 1.2 and 2.2 are
complete (2/19). Default-watch work contributes to 3.1; it does not complete
conflict orders, routing, publication admission or native custody.

The branch was refreshed onto main `95d97be`. Schema32 remains reserved and
unpublished; the migration has not been applied to farm01. Production conflict
routing must remain disabled. No PR, native publication run or deployment has
been initiated for this checkpoint.

## Implemented boundaries

- Owner-fenced branch binding through the packaged Go CLI and Phoenix API;
  schema32 Ash resources, audit events, versions and additive migration.
- Exact pushed SHA checked against the repository's freshly read actual default;
  conflicting, shallow and unknown evidence refuses publication. Behind-clean
  evidence warns. This hook does not gate native PR creation.
- Default ref/tip kept separate from the PR target ref/tip through the existing
  admitted, bounded collector and BaseMonitor. Default advancement invalidates
  all enrolled open PRs. Sorted watch locks fence stale results; repeated
  invalidation pages retain already-updated reservations.

## Remote verification

| Evidence | Result |
| --- | --- |
| [Combined publication, binding, schema, conflict, CI, workflow and CLI checks](https://carverauto.buildbuddy.io/invocation/73466c44-0c1f-46c5-b256-9e425293e881) | 9/9 passed before the private invalidation-helper refactor |
| [Final default-watch and legacy conflict checks](https://carverauto.buildbuddy.io/invocation/3c23ed01-0acb-434e-a6f8-6bdd6b33e79d) | 2/2 passed after that refactor |
| [Missing default-watch regression](https://carverauto.buildbuddy.io/invocation/ccf3ffb3-6f80-4b3a-b2bb-95fa24c043b2) | Expected RED before implementation |
| [Invalidation replay regression](https://carverauto.buildbuddy.io/invocation/4beb0738-c80a-4767-8525-be87f94efef5) | RED before replay fencing |

Tests execute the packaged application against invented HTTPS provider replies
and real ephemeral PostgreSQL, or executable disposable Git fixtures. No
workstation compilation, fabricated native receipts or production activation.
The final runtime configuration edit restores unrelated formatting only.

Ripwire's static graph cannot trace the Python/RPC test callers and is not
coverage proof. The default-watch delta has no remaining major gate after
reducing invalidation complexity and recording scoped short-horizon churn
acknowledgments on four changed collector/watch resources. Minor and new-symbol
debt remains; this is not a claim that the whole branch is quality-clean.

## Integration decisions still required

The published v1 envelope requires one canonical Message in both delivery modes.
#122's supplied `Runtime.fallback/4` instead returns Event in worker mode and
Message in inbox mode. #156's typed Message capture cannot consume that Event
(board msg1703). #122 confirms this distinction is deliberate and asks for a
coordinated existing-Event contract amendment (msg1711). No second election,
message or native prompt may be fabricated to bridge the mismatch. Its worker
health eligibility correction remains in its native publication pipeline.

Installed No-mistakes v1.84.0 has no verified supported PR-open/update admission
adapter or cross-seat custody-transfer receipt. Direct native host PR calls
bypass a pre-push-only gate. An upstream implementation owner and executable
acceptance evidence are required; the Agentboard seat has no assignment to edit
that separate repository (coordinator question msg1663).

Orders, deadline routing, public grants, native same-PR repair, dashboard
projections and activation remain unfinished. Nothing in this checkpoint grants
another seat permission to mutate an active publisher's worktree, run or refs.
