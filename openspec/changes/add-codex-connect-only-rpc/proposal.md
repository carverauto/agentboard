# Add an unregistered connect-only Codex RPC client

## Why

The native queue core needs real, bounded WebSocket-over-UDS framing and safe
existing-daemon discovery before any installed interoperability test is possible.
A mock request client alone cannot exercise those boundaries. Owner-issued
native lifetime, connected-peer and recipient proof are still missing.

## What changes

- Add an isolated one-connection client at the exact `rust-v0.162.0` source pin.
- Discover only the official protected Unix alias layout without repair/spawn.
- Require explicit external owner proof before initialize and ready identity;
  provide the owner the actual connected stream, never fabricate incarnation.
- Pin reputable ws framing and bound HTTP/messages/fragments/queues/deadlines.
- Add synthetic HTTP/WS, path and queue-core fixtures plus mandatory hosted and
  remote-Bazel invented Unix-socket coverage.

## Capability

New: `codex-connect-only-rpc`. No runtime or admission capabilities are modified.

## Exclusions

No activation, daemon/session lifecycle, board writes, credentials, owner election,
source handling, wake journal/recovery changes, registration, deployment or Mac
execution. No evidence provider ships. Native initialize has process metadata,
automatic gateway-login and subscription effects and remains a separate live gate.

Work uses an explicitly authorized ordinary linked assistant-VM worktree from
main `2b93dbfcb0923025ea93b3ab25eeb719d7edec91`; no Treehouse lease is fabricated.
