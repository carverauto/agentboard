# Design

## Context
See proposal.md. Runtime.capture currently freezes a non-revoked subscription audience without a board fallback. Accountability reminders require a worker; Rebase emits an independent owner message and bootstrap explicitly adds late-worker deliveries.

## Goals / Non-Goals
The board inbox must survive zero-worker operation with one logical event/receipt. Host wake adapters, production enablement, polling-budget changes (#115), decision authority and Mattermost cutover are separate work.

## Decisions
1. Extend the immutable cooperation event with delivery mode, recipient, message ID and reason. Its existing unique source_key owns dedupe. A capture advisory transaction lock serializes retry/race creation; the message and event commit together. A separate receipt table would duplicate the canonical event identity.
2. Only CI failure/reminder/digest and conflict signals use fallback when cooperation is enabled. Ordinary context/task audiences retain their current behavior. Resolve registered responsibility -> repair assignee -> configured coordinator; explicit captain digest targets the coordinator. Missing coordinator/recipient is retained as undeliverable, never a broadcast.
3. Freeze route at capture. Enabled, non-revoked, unpaused repo subscriptions select worker; otherwise board message. ensure_delivery skips events with inbox receipts, including late enrollment bootstrap. Old undelivered events remain eligible for worker bootstrap. This does not replay old empty-audience events into inbox.
4. Count worker and inbox reminders together under the existing sweep lock and 4/hour limit. Preserve current-failing freshness, blocker guard, 900s reminder / 3600s escalation cadence and hourly digest source key.
5. Under cooperation-on, conflict notice comes from this common path; remove the independent owner notice in that mode. Flag-off preserves it. Resolution retains immutable receipts and does not manufacture another wake.
6. Add schema26 fields/constraints and GREATEST(version,26); keep migration and global schema requirements compatible with main. No credential provisioning or physical prompt is part of this feature.

## Risks / Trade-offs
- Inbox insertion failure -> roll back message/event with the collector transaction, allowing an explicit retry.
- Enrollment races -> immutable route plus capture serialization and bootstrap receipt guard prevent duplicate paths.
- Retained unread messages can outlive recovery -> record the original signal honestly; do not resend or overwrite immutable evidence.
- Event receipt is a board delivery guarantee, not proof that a host physically woke the seat.

## Migration Plan
Deploy prebuilt schema26-compatible release through existing workflows; missing migration keeps readiness unavailable. Cooperation flag controls fallback activation. Preserve additive data on rollback to a compatible release; do not drop receipt/history fields.
