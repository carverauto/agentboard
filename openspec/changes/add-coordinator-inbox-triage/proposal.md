# Deterministic coordinator inbox triage

## Why

[Issue #186](https://github.com/carverauto/agentboard/issues/186) asks the server to absorb routine coordinator inbox work and emit a signed coordinator notification only for explicit judgment or captain-addressed messages. The current inbox sweep cannot be retired merely because classification exists: deterministic routes, reliable escalation, unresolved visibility and live equivalence all need proof.

This is a proposal only, based on main `1ea2d332d7b3a7fc70970d266f0172d54c9e9dbd`. No implementation or activation approval is recorded here.

## What Changes

- Add versioned, explicit message triage metadata and six normalized classes: status, CI, conflict, next-work, needs-judgment and captain-addressed. Never classify prose, mentions, titles or model output.
- Retain one audited triage identity per canonical Message ID. Capture metadata, source references and initial disposition atomically; retries cannot create a second logical escalation.
- Record informational status without inventing work. Reference existing #122 CI/conflict delivery and #156 canonical wakes. Next-work can adopt an existing authorized assigned-card wake; it cannot pick, assign or claim another task.
- Keep missing owners, unclassified legacy messages, invalidated sources, unsupported native routes and failed delivery visible. Expose routing independently of inbox read/handled receipts; do not auto-ack in v1.
- Specify one producer adapter to [#153](https://github.com/carverauto/agentboard/issues/153) for public-ID/link-only signed escalation. Reuse its outbox, signing, retries, rotation and dead letters. Exactly one logical event per Message ID permits multiple at-least-once delivery attempts.
- Default off; progress through shadow comparison and explicitly approved activation. Keep the inbox sweep until live equivalence and recovery evidence justify a separate retirement decision.

## Capabilities

### New Capabilities

- `coordinator-inbox-triage`: explicit classification, transactional audit, deterministic existing-route adoption and truthful unresolved reads.
- `coordinator-escalation-adapter`: message-ID-idempotent producer contract with the #153 signed transport and a replay-safe consumer.
- `coordinator-triage-rollout`: default-off staging, compatibility, operational proof and reversible sweep cutover.

### Modified Capabilities

None. The main specification inventory is empty. This change preserves the existing unarchived #122/#156 contracts and records their observed limits rather than rewriting another owner's proposal.

## Impact

Future implementation touches Board Message/Operations/Reads, message API/CLI, an audited triage resource, existing producer capture seams, wake capture/reconciliation eligibility, read-only dashboard visibility and the #153 producer adapter. An additive migration will need a separately reserved identifier after approval; none is allocated by this proposal.

The standalone classification/audit/visibility slice can be implemented after approval without #153. Real coordinator delivery is blocked on that transport. Native seat delivery and typed conflict currentness remain bounded by #150/#156/#169; their absence must remain explicit.

## Non-goals

Product code in this PR; a second outbound transport, CI selector, native wake owner or polling coordinator; decision answers/policy (#154/#145); stale-seat recovery (#164); automatic assignment, lease changes, receipt fabrication or conflict repair; credentials, enrollment, schedules, webhooks, production enablement, deployment or retiring any live routine.
