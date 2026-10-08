# Design

## Context

Phase 1 (`Conversations.post_as/8`) already funnels every send through one pluggable seam with the shared bot token from `Delivery.bot_config/0`. Registration flows through `Operations.register/2` with an identity lock (`lock_identity/1`) that serializes same-id registers — the natural fence for exactly-once provisioning. No encryption library or roster GC exists yet; GC (#42) is owned by codex-agent-a-server with an agreed `ElasticBots.retire/1` hook (idempotent, never raises).

## Goals / Non-Goals

**Goals:**

- Transparent swap: `post_as` picks the agent bot token when active, shared bot otherwise; CLI, props, header, and diagnostics shape unchanged.
- Exactly-once bot per agent id under register races; provisioning never fails registration.
- Tokens encrypted at rest via `ash_cloak`; zero leakage surface.

**Non-Goals:**

- Inbound routing changes (5.3, codex-agent-b-worker owns; real `@bot` mentions handled there).
- `dual`-mode or cutover gating (NOT blocking per #82).
- Farm01 provisioning of the provisioner credential itself (captain/MM-admin, Secret ref).

## Decisions

- New `Agentboard.Mattermost.ElasticBots` module owns `ensure/1` (called from the register path after commit) and `retire/1` (called by roster GC). Provisioning runs in an Oban job, not inside the register transaction, so MM latency/outages never touch registration; a `pending` mapping row plus unique index on `agent_id` gives exactly-once under races (second job adopts).
- Short-name scheme: `ab-` prefix plus compressed agent id, truncated with a deterministic hash suffix on collision, verified to 22 chars; mapping keyed by Mattermost user id; full agent id as bot display name.
- `ash_cloak` with a key from the existing Secret-based config pattern (file-backed key ref, never in repo); token column is `AshCloak.Encrypted.Binary` equivalent for the project's Ash version.
- `post_as` resolves the token per send: active bot token → shared bot fallback with existing override gating. Revoked/invalid token observed at send → mark mapping `stale`, enqueue re-provision, fall back this send.
- One migration (17, reserved): `mattermost_agent_bots(agent_id unique, mm_user_id unique, username, display_name, encrypted_token, state, timestamps)`.
- Diagnostics extends the existing overrides object with a `bot` object (`{active: bool, username|null, state}`) — no secrets.

## Risks / Trade-offs

- Provisioner credential is a high-privilege server secret: file-backed ref only, rotation runbook, and sends never log it. If the credential is absent, everything stays on phase 1 (explicit diagnostics state).
- Bot-per-agent multiplies MM API calls at register bursts; Oban backoff plus idempotent adopt keeps it bounded.
- MM v12 override deprecation is the forcing function; until the flip, mixed fleets (bot + override posts) are normal and props keep them uniform.
