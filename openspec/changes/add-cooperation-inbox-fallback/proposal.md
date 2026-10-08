# Proposal

## Why
With cooperation enabled and no enrolled workers, CI failure, reminder and escalation events are retained with an empty audience and reach no seat. The packaged regression on main21e907c demonstrates the missing responsible-owner inbox message (BuildBuddy9d0b98b6).

## What Changes
- Route CI and conflict follow-ups to an enabled, unpaused scoped worker, or one durable board inbox message.
- Resolve the recipient from responsibility, repair assignee, then configured registered coordinator; retain an undeliverable reason when none exists.
- Preserve flag-off behavior, reminder generations/cadence/cap, and suppress bootstrap replay after inbox delivery.
- Expose immutable delivery mode and receipt on PR/obligation reads and /prs.

## Capabilities
### New Capabilities
- `cooperation-follow-up-delivery`: durable worker/inbox selection, receipt and enrollment continuity for CI/rebase signals.
### Modified Capabilities
None; this repository has no archived capability specs.

## Impact
Cooperation capture/enrollment, Accountability reminders, Rebase notices, PR reads and LiveView. Additive schema26 migration, no new dependency or host wake mechanism.
