# Duplicate PR evidence and publication guard

GH #110 adds possible duplicate evidence without automatically closing PRs,
creating decisions, assigning work or renewing claims. Captain ruling949 chose
an owner-initiated CTA on the duplicate's own non-terminal linked card. The
collector never impersonates a worker. Decisions use the existing #100 boundary.

The HTTPS collector retains bounded head repository/ref metadata in immutable
snapshots. A per-PR reconciliation transaction compares the current open
snapshot with retained merged PRs in the same target repository. Same head
repository/ref or a shared retained task submission produces one durable Ash
finding with both snapshot IDs. Matching branch names in unrelated forks are
independent. Missing historical head metadata cannot prove branch identity.
A minute AshOban reconciliation handles late/out-of-order original observations.
Task locks precede per-finding locks; no provider I/O happens under those locks.

`/prs`, PR details and linked cards show the finding. The actual live duplicate
card owner can run the displayed command:

```sh
agentboard pr duplicate-decision CANONICAL_PR_ID --task DUPLICATE_TASK
```

The API derives a stable task/gate request, verifies the duplicate task link,
then uses the existing owner-only decision API. Retrying returns the same
request. A request parks the owned card. An original Done card is never used to
host the decision. The captain's answer guides the owner's later action; this
endpoint does not call GitHub to close or keep anything.

Cooperation-disabled observation still records findings. When enabled, the
finding's recipient receipts and audited board messages commit together,
including when no worker is enrolled. Retries deliver at most one notice to
each current owner/coordinator recipient. Shared routing can adopt #122's
fallback contract when that dependency lands. There is no host wake or global
installation in this change.

The additive migration reserves24 per captain949 (main22, PR126 reserved23).
It uses GREATEST, never lowering a higher stamp. The release upgrade test runs
the actual schema22 migrations, retains task/history/HTML prefixes, then runs
24 twice with a preexisting25 stamp: prefixes and higher stamp survive, and no
findings are seeded. The PR merged second must reconcile the ordinal with main.

## Publication boundary

`scripts/publish-seat TASK -- run ...` verifies the leased seat, live task
ownership, linked PR and same-head merged history before native AXI publication.
It binds a pre-push hook only to that task branch in the explicitly configured
bare no-mistakes mirror and preserves its post-receive hook. Use the wrapper for
respond/rerun too. Terminal/merged evidence means stop, inspect custody and
abort an obsolete active run from the outer driver; coordinate a remaining
fresh-main delta. Hooks never drive or abort the native pipeline themselves.

The hook cannot make GitHub merge and Git push atomic or intercept a PR-only
daemon step. Upstream [no-mistakes1371](https://github.com/kunchenguid/no-mistakes/issues/1371)
tracks the remaining in-flight race. Unbound historical refs are outside the
registered task guard. Provider verification failure refuses publication.

## Evidence

- Intended pre-fix failure: [remote baseline](https://carverauto.buildbuddy.io/invocation/666a9c65-66ea-4b54-819b-04cc27897522). An earlier fixture/private-function failure is not regression evidence.
- [Current CLI floor + regression pass](https://carverauto.buildbuddy.io/invocation/9d0c7d2d-a1be-4c6b-b350-f205db08af0c): new write rejects schema22/23 before mutation; TLS duplicate regression passes.
- [Corrected regression pass](https://carverauto.buildbuddy.io/invocation/63fce502-ce2d-4758-9cba-76085e5a3a1d): actual TLS provider, Ash collector, API/CLI and connected LiveView. Branch/task replay, forks, retry notices, owner-only/idempotent CTA, unchanged Done original and late merge all pass.
- [Upgrade and integration proof](https://carverauto.buildbuddy.io/invocation/0c21de67-4dc5-41c8-b0f1-1b75f6cacda2): release-schema, decisions, paging and merge disposition pass. Duplicate target failed on missing LiveView runfile there, corrected in the separate pass above.
- [Publication and seat isolation](https://carverauto.buildbuddy.io/invocation/1fa41e7e-d93d-4712-b3d8-60cf5fcd7499): real Git pushes, positive control, terminal/merged refusal, fork isolation, provider-error refusal and native post-receive preservation (cached remote results).

[Architecture HTML](../architecture/duplicate-pr-guard.html) and its retained
JSON source explain the boundaries. Archify delivery:9/9 showcase,0 errors/0
warnings. Specification SHA2561a71bf9c7582d92865c7d4814870c541391c37136c95cba0838526e2253686fe;
HTML SHA256fc56f00c732d150049899377f7ca6c2d5f421ef453195548c72f635313c0ef21.
Automated browser evidence passes1440x900,1600x1000,1920x1080,2048x1320;
image review of both endpoint sizes/themes passes. Correction rounds:1.
The abandoned workflow layout did not pass readability and is not delivered.

Native no-mistakes publication/CI and task document upload remain pending until
reported on the live card. No merge or deployment is authorized by this receipt.
