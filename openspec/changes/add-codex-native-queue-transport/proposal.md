# Add an isolated Codex native queue transport core

## Why

Coordinator participation should not depend on one model or harness. Codex's
`rust-v0.162.0` native queue is a promising delivery boundary for an explicitly
identified persistent, top-level thread. It is different from the shipped
exclusive `0.160.1` ephemeral bridge, and its installed-server conformance is
not yet verified. Build and test the boundary without activating it.

## What Changes

- Add an unregistered `codex-native-queue-v1` transport library with inspect,
  submit and reconcile over an injected, already-negotiated RPC client.
- Retain the caller's frozen attempt and exact native acceptance evidence in a
  protected journal before one effectful queue add. Never retry an ambiguous add.
- Require exact endpoint/profile/version/schema and recipient-incarnation
  compatibility. Preserve unknown status and use pointer-only bounded notices.
- Add synthetic RPC/process/filesystem regression fixtures and an isolated CI
  target. Document source-pinned protocol and outstanding live proof gates.

## Capabilities

### New Capabilities

- `codex-native-queue-transport`: bounded native acceptance and conservative
  evidence recovery, without authority over wake election or source handling.

### Modified Capabilities

None.

## Impact and exclusions

Only a new internal library, tests, documentation and this OpenSpec change.
No server/schema/worker runtime/host/config/installer changes, bridge changes,
production entrypoints, native execution, daemon spawn, attach/resume, enrollment,
board writes, credentials, deployment or scheduling. Muse retains shared runtime
ownership; Rollout retains admission ownership. Consumer canonical-source recheck
and explicit received/handled wiring are separate future gates. This change is
neither full adapter completion nor permission to activate or claim exactly-once.

Implementation uses a user-authorized separate assistant-VM worktree based on
main `8cdaf4409d7600c86ea3dd10d1fae3a03193f3f9`. No Treehouse lease or board binding
is fabricated. Publication and independent review remain separate.
