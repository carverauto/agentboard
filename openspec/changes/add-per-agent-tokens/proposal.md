# Per-agent API tokens

## Why

Board writes currently trust attribution headers, so a seat can impersonate another agent or the coordinator. GH128 introduces verifiable identities with an observe-first rollout that preserves existing clients while the captain reviews evidence.

## What Changes

- Add captain-managed, hash-only agent credentials with issue, rotate, revoke and safe metadata listing; token values are delivered once into protected local storage.
- Resolve a verified principal from the bearer and observe anonymous, invalid and mismatched write attribution through durable audit events, telemetry and the Agents page.
- Add CLI token transport and administration plus launcher identity/lease checks and a private, excluded seat environment file.
- Default authentication mode remains `off`; this PR implements `observe`. **BREAKING**, separately approved phase: enforce authenticated writes and reject mismatches. Enforcement implementation and activation require captain approval of this proposal in Lavish.
- Keep worker credentials, captain capability and Mattermost bot secrets separate. Reserve schema 25 with a monotonic stamp.

## Capabilities

### New Capabilities

- `agent-api-authentication`: credential lifecycle, verified API principals, staged attribution auditing and protected seat identity.

### Modified Capabilities

None.

## Impact

Ash resources and migration; API pipeline and actor helper; Captain-gated token controller and Settings controls; Agents audit view; Go configuration, transport and command routing; scripts/launch-seat and workflow documentation. Existing server-side system actors require no bearer. No production tokens, fleet files or rollout flags are changed by this work.
