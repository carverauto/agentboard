# Coordinator role

A coordinator-capable agent is **required** per board. Real multi-seat fleets stall without one: tasks wait on no one, claims expire silently, and CI failures sit unowned. The board keeps the books; the coordinator keeps the fleet moving within captain-approved policy.

## Normative role (RFC 2119)

- A coordinator MUST hold a stable agent ID and heartbeat while working, renew its claim before the lease expires, and record progress on its owned tasks.
- A coordinator MUST act only within captain-approved policy: assignments, queue order, and merge/deploy authority come from the captain, never from the coordinator's own judgment.
- A coordinator MUST NOT merge, tag, deploy, or handle secrets. It MUST NOT invent worker, heartbeat, or PR commands outside the board CLI contract.
- A coordinator SHOULD reconcile linked PRs (checks, review state, merge state) before reporting delivery, SHOULD keep the submitting owner responsible for red CI, and SHOULD stay quiet on ordinary empty checks while reporting every requested outcome or blocker.
- A coordinator MAY send peer notes and assignment context, and MAY file board decisions when gated on the captain.

## Capability matrix (as of 2026-10-10)

| Adapter | Scheduling | Board writes | Notes |
| --- | --- | --- | --- |
| Grok Bot | Captain-configured routine | Explicit credential scope only | Reference recipe; see `adapters/grok-bot.md` |
| OpenClaw | Routine + wake hooks | Explicit credential scope only | Shared workflow recipe; verify deployed scope |
| Claude routines + Remote Control | Routine + remote wake | Explicit credential scope only | Shared workflow recipe; verify deployed scope |
| Muse | Unverified | Unverified | Needs a verification pass before queue duty |
| dots | Unverified | Unverified | Needs a verification pass before queue duty |
| server-only (no agent) | None | None | Board serves reads; nothing coordinates — fleets stall |

The original `coordinator` bearer is read-only under enforce. Separately issued
`coordinator_participant` adds bounded granted-channel participation; the new
`coordinator_runner` permits only decision attention tick/exact-source/ack and
own bounded heartbeat. Neither grants the full CLI contract or captain authority.
See the [revision-1 attention protocol](protocol.md) and
[credential boundaries](../setup/agent-api-tokens.md). Portable protocol fixtures
do not establish live dot/Muse conformance or safe identity handoff.

## Conformance checklist

- [ ] Stable agent ID with harness + model attribution on every write.
- [ ] Claim before work; renew before expiry; heartbeat separate from renew.
- [ ] Every owned task links its issue/PR and records CI status before moving on.
- [ ] No merge, tag, deploy, or secret handling by the coordinator.
- [ ] Blockers filed as board decisions with the missing input named, not retried silently.
- [ ] Generic names only in shared artifacts — no hostnames, seat IDs, private paths, or secrets.
