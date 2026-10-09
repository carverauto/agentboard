# Captain-managed seat scope admission

## Why

Issue #60 needs durable captain authority over which repositories and labeled pools each seat can receive. Self-reported metadata and cooperation enrollment do not constrain task claims. This additive foundation implements that boundary without replacing the retained FleetLoadout/host/Deck design or starting its runtime.

## What changes

- Audited per-agent `SeatScope` records, edited only with existing verified captain capability.
- Explicit canonical repositories, required-label ALL and allowed-label ANY matching, conjunctive with availability and retirement.
- Central claim/assign/handoff/reclaim and typed task-order admission, plus guarded edits of owned task routing fields.
- Scope read/full-replacement API and CLI, and captain editor on Agents with visible Managed/Unmanaged state.
- Scope-safe cooperation provisioning; retired workers cannot reserve new or replayed batches. Existing receipt/reconciliation remains available.

## Non-goals

No desired seat count, model/effort configuration, FleetLoadout reconciliation, host launch, Deck plugin, scheduler, native wake activation, merge or deployment. No independent role enforcement: neither tasks nor seats have a trusted operational-role model. Names, capabilities and arbitrary labels are not inferred roles. This is a partial #60 implementation; the epic remains open.
