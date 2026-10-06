# Proposal

## Why

The captain needs architecture and feature PRs to arrive with visual documentation, visible from their task. Current tasks link only to an issue and PR, and Agentboard cannot retain or serve HTML. OpenSpec proposals also need automatic Lavish rendering.

## What Changes

- Require Archify HTML for feature and architecture/design PR delivery in the canonical agent workflow and captain checks, inherited by every harness.
- Automatically render OpenSpec proposals into a Lavish review surface.
- Add API-only CLI document upload/list commands, immutable attributed PostgreSQL storage, task links, download and sandboxed HTML serving.
- Keep files bounded to 2 MiB and metadata separate from HTML in ordinary board reads.

## Capabilities

### New Capabilities
- `task-documentation`: Persist, link and serve attributed task documentation; require visual delivery and OpenSpec review in agent skills.

### Modified Capabilities
None.

## Impact

Additive schema migration; Phoenix API/controller/context and LiveView task detail; Go CLI and release acceptance; canonical skills and documentation. No new runtime service or database query GenServer.
