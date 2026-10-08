# Duplicate-PR guard checkpoint

GH110: https://github.com/carverauto/agentboard/issues/110

This is an unfinished implementation checkpoint, not a delivery receipt. Base
main1321dc08505278c3451eeeeb24cc39a1b0817c48. No application migration,
duplicate resource, dashboard flag or decision mutation has been implemented.

## Proven behavior

The corrected remote baseline reproduces the missing duplicate flag through a
real HTTPS provider and the fenced Ash polling callback. It first observes A
merged, completes its Review source using the public Ash action, observes B
open on the same head repository and branch, and fails at the missing
`duplicate_of` assertion:
https://carverauto.buildbuddy.io/invocation/666a9c65-66ea-4b54-819b-04cc27897522

An earlier fixture accidentally invoked a private function; invocationd6017968
is not bug proof. The correction is retained in the regression.

The prepared publication guard and existing seat-isolation suites pass remotely:
https://carverauto.buildbuddy.io/invocation/bb7194a8-1f55-4c0b-affa-c13dcf7a9360

The guard test executes actual Git pushes from a separate linked worktree in a
bare native-style gate. Its pre-install and still-open controls succeed; terminal
task, merged linked PR and merged same-head-branch controls refuse publication
without recreating the target branch. Same spelling in a different fork remains
independent. Provider failure is refused, sensitive stderr is not echoed, the
native post-receive hook is preserved, and primary-cwd invocation is rejected.
The wrapper refuses terminal publication before invoking native run control.
The actual no-mistakes daemon has not been driven with this new wrapper yet.

The upstream in-flight repair/rebase issue is filed:
https://github.com/kunchenguid/no-mistakes/issues/1371

## Remaining design and authority

Detection must persist immutable evidence (candidate and merged canonical IDs,
proof snapshot, basis and timestamps) through Ash, without changing task status,
ownership, CI qualification or closing a PR. A cooperation-gated once-only
notification marker must include both submitting seat and configured coordinator,
including the un-enrolled inbox path. Unknown historical head metadata does not
prove a matching branch. Compare head repository as well as ref, and preserve
terminal evidence independently of inventory visibility. Concurrent/late
observations need explicit ordering and rollback coverage. The current
`duplicate_pr_test` remains intentionally red until that implementation exists.

Agent A's current PR125/Context203 decision contract permits requests by the
actual live task owner. A Done task cannot receive a request; the collector must
not manufacture an owner actor. Required coordinator decision: owner-initiated
CTA using that existing boundary, or a separately authorized system-generated
request/follow-up contract. Do not silently skip required decisions when the
module is absent. Prefer implementation after PR125 merges.

Schema main is21; open PR118 reserves22. Coordinate the next additive migration
ordinal before writing a conflicting schema change. No schema number is assigned
to this checkpoint.

The publication wrapper binds a native pre-push hook only to the current task
branch in the explicitly configured local bare mirror. Unbound legacy branches
and evidence refs are outside its scope. It fails rather than replacing foreign
hooks. The hook does not call abort from inside a pipeline step. The outer driver
inspects custody and aborts an obsolete active run after verifying terminal state.
It cannot make a GitHub merge and Git push atomic or intercept a PR step that
publishes without a Git push; upstream1371 owns that remaining daemon fence.

Archify, any accepted OpenSpec/Lavish proposal, full application test proof and
native no-mistakes publication remain required before final delivery. Nothing
has been pushed, merged, installed globally or deployed by this checkpoint.
