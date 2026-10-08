# Publication admission and conflict routing

The `add-server-conflict-routing` OpenSpec change describes the full planned
server path. Its integration contract is in
[conflict-routing-contract.v1.md](architecture/conflict-routing-contract.v1.md).
Do not treat a wake or repair assignment as native branch-write custody.

## Durable binding API

`agentboard publication bind TASK --repo OWNER/REPO --branch BRANCH` creates
retained exact branch/card attribution through `POST /api/v1/publications/bind`
(schema32). For forks, use `--head-repo HEAD_OWNER/HEAD_REPO`; it defaults to
the target repository. The task must name that target repository and have
this actor's live claim with no decision hold.

The response contains `binding` and `idempotent`. Repeating the same mapping
does not create another Ash event/version. Another card cannot take the same
head-repository/branch mapping, even when both cards share an owner. Releasing
the claim preserves attribution but authorizes no publication. A new live
owner can reuse the same card's binding without rewriting the original binder.
Binding changes neither source-task ownership nor lease/status/history.

This API records attribution; it grants no provider or branch-write capability.
The native publication wrapper's server-backed admission/completion adapter
remains a separate implementation task. Until that adapter is proved, the
wrapper's existing local registry and pre-push fence are its supported path.

## Exact-head pre-push check

The outer driver runs `scripts/publish-seat TASK -- run|respond|rerun ...` from
its verified Treehouse seat. The wrapper installs the task-scoped native gate
hook while preserving the native post-receive hook. Validation-step agents
must not drive the pipeline.

For each bound, non-deletion branch in a proposed push, the hook verifies the
current live task owner, absence of a decision hold, and existing PR/history
fences. It then checks the **SHA in Git's pre-push input**, even if the caller
worktree has a different commit checked out. It asks GitHub for the actual
repository default branch; a repository using `staging` is not checked against
a hard-coded `main`.

The hook reads the remote tip, fetches its objects without updating FETCH_HEAD
or branch/tracking refs, and rereads the default-ref identity and remote tip.
It verifies commit/history availability, ancestry, and a read-only
`git merge-tree --write-tree` verdict. This writes Git objects, not the
worktree or native branch. It never rebases, restarts or aborts a run.

| Evidence | Result |
| --- | --- |
| Exact head includes the freshly checked default tip | Continue |
| Head is behind but merges cleanly | Record an attributed warning on the task, then continue |
| Exact head conflicts with the fresh tip | Record conflict evidence and refuse the whole push |
| Fetch/provider failure, changed default/tip, shallow/incomplete history or indeterminate merge | Record unavailable evidence and refuse; reobserve later |
| Task revision changed before an evidence write | Refuse; reload canonical task state before another attempt |

Recorded evidence names the exact head, default ref and tip. It does not
change task status, assignment or lease. Raw provider diagnostics and tokens
are not copied into task history. Other unbound historical/evidence refs
remain outside this task-scoped hook. If one bound ref refuses in a multi-ref
push, Git sends none of the proposed updates.

A final check cannot atomically lock a moving GitHub default branch. The
planned server watch and observation fences must reconcile later advances.
An unknown result is never clean, and a clean merge does not prove CI green.

## Native capability prerequisites

A Git hook does **not** gate PR creation or automatically record its URL.
Installed No-mistakes v1.84.0 lacks a proved PR-open admission callback and
cross-seat custody transfer interface. These remain explicit implementation
prerequisites for OpenSpec tasks 2.3 and 4.3; no replacement write grant may be
issued on the basis of a wake, fixture receipt or shared Git credential.

The eventual native adapter must preserve the original run and every pipeline
fix, prove terminal/quiesced custody, bind its receipt to repository/ref/head
and generation, and publish only the existing PR with exact remote-head CAS.
Active original monitors retain their own repair/revalidation custody. Missing
or divergent capabilities must produce a visible captain escalation.

## Verification boundary

`//build/integration:publication_guard_test` executes real pushes from a private
native gate against invented Git repositories/provider replies. It covers
terminal and merged-branch refusal, fork isolation, preserved native hooks,
an advanced `staging` default, exact-SHA conflict refusal, current and
behind-clean controls, shallow history, decision holds, multi-ref refusal and
unavailable provider/fetch evidence.

`//build/integration:publication_base_api_test` sends the hook's evidence through
the real packaged Go CLI and Phoenix API against ephemeral PostgreSQL. It
checks attributed history, unchanged ownership/status/lease, and revision-race
refusal. Fixtures supply neither admission receipts nor task evidence.

Run both remotely with `./scripts/bazel test` and the two target names. No
workstation builds or tests. These tests do not certify native PR-open gating,
cross-seat custody or host activation.
