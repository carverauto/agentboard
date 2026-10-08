# Proposal

## Why

Already-running agent sessions can lose their seat environment and stop even while owning an isolated task worktree. Recovery currently depends on a coordinator supplying paths, and a primary-checkout session has no packaged way to acquire and attach safely.

## What Changes

- Add packaged `agentboard seat ensure|env|check TASK` commands using the existing launcher's pinned Treehouse and physical Git/lease checks.
- Bind one seat to a task, actor, source, pool and durable lease identity; serialize acquisition and reuse the binding across retries without resetting work.
- Print shell-quoted, non-secret exports and a `cd` command for an existing session; JSON supports launcher integrations. Commands cannot mutate their caller's shell or Herdr workspace.
- Add explicit `launch-seat --attach --task TASK` reuse and preserve seat variables in the protected launch environment. Fresh task launches use the same resolution contract.
- Teach shipped canonical, Codex, Muse and Herdr skills to self-heal missing environment before escalating genuine ownership or isolation failures.
- Keep primary/source edits forbidden, legacy/out-of-pool worktrees rejected, credentials private and leases retained through delivery.

## Capabilities

### New Capabilities

- `seat-attachment`: owned-task seat acquisition, durable reuse, secret-free environment handoff and fail-closed native attachment.

### Modified Capabilities

None. No main specification currently owns seat isolation; existing launcher behavior remains the foundation.

## Impact

Go CLI packaging, `scripts/launch-seat`, shipped skills and seat setup documentation. The CLI embeds the existing Python 3 launcher so another repository needs only the installed CLI, Git, Python 3 and the pinned Treehouse binary; no clone of Agentboard is required for recovery. Board access stays API-only and uses existing task events, requiring no server migration or Herdr installation changes. Captain msg1255 authorizes planning and implementation in the same PR; #57 remains an independent update-channel proposal.
