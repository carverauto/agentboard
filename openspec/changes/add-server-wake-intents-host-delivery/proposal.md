# Proposal

## Why

A durable inbox does not reliably resume a parked seat: the coordinator currently sends individual nudges, and missing host delivery leaves answered decisions or shipped blockers unnoticed. Server-owned wake reasons plus a fenced local delivery owner can remove that dependency without confusing prompt submission with task ownership or completed work.

## What Changes

- Add an audited, transport-neutral wake intent ledger for unread DM, decision answered, claim expiring, idle with assigned work, and blocker shipped. Each occurrence has a stable recipient/reason/subject-version hash; repeated reconciliation does not invent a new occurrence.
- Reuse existing decision wakes, cooperation source capture, frozen batches, scoped credentials and exact handling receipts rather than dispatch the same answer through a second queue.
- Add a proposed `agentboard host run` orchestration surface that pulls eligible intents and uses the existing worker journal/locks. The hosted server never opens a Herdr socket. Proposed commands are not claimed to exist today.
- Integrate the owning #150 `seat nudge` / `host schedule install` work through one shared admission and safe-input contract. Herdr is the first transport to validate, but stays disabled unless the installed profile proves exact recipient identity, safe atomic submission and reconciliation. Backend metadata is insufficient.
- Provide dry-run parity evidence and per-binding readiness, then retain the current nudger until a separate captain-approved cutover. File installation previews do not start services or register hooks.
- Reserve an independently gated `seat.restart` transport extension for #164's approved incarnation fences. Ordinary wakes never kill or recreate a session, renew a claim, release ownership, apply an answer or activate recovery policy.

## Capabilities

### New Capabilities

- `wake-intents`: durable reason occurrences, canonical source reconciliation, bounded deduplication, reservation and explicit transport/handling disposition.
- `host-wake-delivery`: locally owned authenticated dispatch, safe native boundaries, uncertainty reconciliation, readiness and explicit cutover.

### Modified Capabilities

None in the main spec inventory (currently empty). Preserve and reference the in-flight `align-agensh-worker-runtime` delivery/harness requirements and `add-idempotent-seat-attachment`; do not duplicate their adapter implementation checklists.

## Impact

Proposed implementation touches Phoenix/Ash intent resources/actions and API readers, existing cooperation/decision capture, Go host orchestration around `internal/worker`, CLI host commands and owned supervision previews, plus compact read-only readiness UI. Reuse #141 seat ensure/env/check and #150 nudge/schedule boundaries. #123 supplies explicit blocker links/terminal-event facts; legacy free-text blockers remain manual. #154 policy and #155 escalation remain separate prerequisites for active #164 recovery. A fresh schema reservation is required before implementation; no version is allocated by this proposal. Tests/builds run remotely only. Production enrollment, service/hook/secret activation, fleet reconciliation, Deck UI and other harness parity remain held.
