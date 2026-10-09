# Design

## Context
See proposal.md. Runtime.capture currently freezes a non-revoked subscription audience without a board fallback. Accountability reminders require a worker; Rebase emits an independent owner message and bootstrap explicitly adds late-worker deliveries.

## Goals / Non-Goals
The board inbox must survive zero-worker operation with one logical event/receipt. Host wake adapters, production enablement, polling-budget changes (#115), decision authority and Mattermost cutover are separate work.

## Decisions
1. Retain delivery evidence in the existing tables (no new event columns, no new receipt table): the event's unique source_key owns dedupe, the canonical inbox message carries the exact `[coop-fallback source=<source_key>]` marker, and `/prs` derives the mode from worker deliveries versus that marker. A `fallback:` source-key advisory transaction lock serializes retry/race election; the message and event commit together.
2. Only CI failure/reminder/digest and conflict signals use fallback when cooperation is enabled. Ordinary context/task audiences retain their current behavior. Resolve registered responsibility -> repair assignee -> configured coordinator; explicit captain digest targets the coordinator. Missing coordinator/recipient is retained as undeliverable, never a broadcast.
3. Freeze route at capture. Enabled, non-revoked, unpaused repo subscriptions select worker; otherwise board message. ensure_delivery skips events with inbox receipts, including late enrollment bootstrap. Old undelivered events remain eligible for worker bootstrap. This does not replay old empty-audience events into inbox.
4. Count worker and inbox reminders together under the existing sweep lock and 4/hour limit. Preserve current-failing freshness, blocker guard, 900s reminder / 3600s escalation cadence and hourly digest source key.
5. Under cooperation-on, the conflict owner notice is retained but carries the exact source marker, so the common fallback adopts it instead of sending a second DM (markerless notes are never adopted). Flag-off preserves the legacy notice unchanged. Resolution retains immutable receipts and does not manufacture another wake.
6. WITHDRAWN per coordinator ruling (msg 1646): no schema migration ships with #122; the single-source design keeps the existing tables. No credential provisioning or physical prompt is part of this feature.

## Risks / Trade-offs
- Inbox insertion failure -> roll back message/event with the collector transaction, allowing an explicit retry.
- Enrollment races -> immutable route plus capture serialization and bootstrap receipt guard prevent duplicate paths.
- Retained unread messages can outlive recovery -> record the original signal honestly; do not resend or overwrite immutable evidence.
- Event receipt is a board delivery guarantee, not proof that a host physically woke the seat.

## Migration Plan
No migration ships with #122 (schema26 request withdrawn per coordinator ruling msg 1646). Cooperation flag controls fallback activation.
