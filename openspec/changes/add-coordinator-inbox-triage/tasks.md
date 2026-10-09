# Tasks

The captain approved the independent implementation slice on 2026-10-09.
[The schema-36 checkpoint](../../../docs/verification/coordinator-inbox-triage.md)
records implemented off/shadow metadata, immutable capture and read visibility.
Unchecked items include broader routing/activation contracts and remote delivery
requirements; transport, deployment and retirement approval are not implied.

## 1. Approval and dependency contract

- [x] 1.1 Obtain captain approval for the explicit metadata, routing matrix, independent read/routed disposition and implementation slices. Preserve proposal-only status until then.
- [ ] 1.2 Agree the exact producer association and lock order with #122/#156 owners; retain #169 currentness and #150 native admission as separate capability gates. Do not contact or assume agreement for an owner from this proposal alone.
- [ ] 1.3 Before implementation requiring storage, obtain a fresh coordinated schema/migration reservation; verify current main and inventory. Slice 1 proposes logical36 / 20261008003600 after read-only inventory; atomic board reservation remains unperformed. See the checkpoint for custody and higher-marker preservation.
- [ ] 1.4 Verify #153's landed contract supplies atomic idempotent enqueue, stable board namespace, one designated coordinator subscription, signing/rotation, bounded attempts/age, dead letters and replay-safe consumer acceptance. Keep transport integration blocked until proven.

## 2. Independent metadata, capture and visibility slice

- [ ] 2.1 Add strict version-1 note metadata and API/CLI validation while retaining legacy inputs and task_order admission. Remotely prove exact accepted fields, invalid shapes and unauthenticated/forged provenance refusals.
- [ ] 2.2 Add audited Message-ID-unique triage identity, append-only disposition history and immutable source references. Remotely prove concurrent exact-ID capture, conflicting retries, source/message/audit rollback and old clients in off mode.
- [ ] 2.3 Implement pure six-way normalization and pending-state source association without body inference. Remotely prove explicit captain precedence, ordinary coordinator recipient not implying captain, malicious body/marker decoys and unsupported legacy states.
- [ ] 2.4 Expose exact non-consuming message/triage reads and paginated unresolved/dead-letter projections in API/CLI/dashboard. Prove source access controls, no-body metrics/errors, unchanged unread/read provenance, large backlogs and lower-ID late commits.
- [ ] 2.5 Add off/shadow modes with auditable configuration revision and deterministic parity output, with new-source eligibility by revision and explicit exact-ID historical activation cohorts. Prove shadow performs no route, webhook enqueue, wake suppression, reservation, receipt, task or native effects.

## 3. Existing-owner deterministic routing slice

- [ ] 3.1 Record status and validate task-event references without changing task/heartbeat state or replying to the sender. Prove taskless status remains scopeless and source mismatch remains visible.
- [ ] 3.2 Link actual CI/conflict producer results from Runtime.fallback without another selector, Message or worker frame. Prove sent/adopted/worker/disabled/undeliverable variants, exact marker ownership, source-key races, coordinator-only fallback and existing late-enrollment behavior.
- [ ] 3.3 Adopt only exact authorized idle assignments and existing #156 reason hashes for next-work. Prove no assignment/claim/lease changes, multiple-task ambiguity, current revision/scope/availability fences and unsupported #150 native route visibility.
- [ ] 3.4 Add explicit projection capture policy and persist coordinator generic-wake eligibility. Prove initial capture, pending reconciliation AND canonical-state/reservation-time checks honor it; prove reserve-versus-enqueue CAS excludes duplicate channels, Mattermost behavior stays intact, typed #169 metadata is not overwritten, and accepted/uncertain preexisting effects block unsafe cutover.
- [ ] 3.5 Implement bounded linkage repair with canonical-source-first locks and no max-ID watermark. Remotely prove late commit, source mutation/retirement/configuration races, full rollback and deadlock-free overlap with #122 enrollment/bootstrap and #156 worker custody.

## 4. #153-dependent escalation slice

- [ ] 4.1 Integrate only #153's transaction-safe enqueue with the stable board/message event key, immutable public-ID/link payload and atomic event linkage. Prove missing transport remains pending and concurrent repair/retry produces one logical event.
- [ ] 4.2 Validate allowlisted server-origin links, no arbitrary recipient/URL, source-read authorization and rejection/redaction of secrets, bodies and remote error text. Prove redirects/SSRF cannot exfiltrate to a different destination under the shared transport policy.
- [ ] 4.3 Prove through the shared #153 transport/consumer that signatures, freshness, rotation/revocation, bounded retries, response loss, payload mismatch and dead-letter replay keep the same event identity and exactly one durable consumer work item.
- [ ] 4.4 Prove routine classes create zero coordinator events and both escalation classes create one logical event per exact Message ID, including dual captain/judgment intent. Keep transport acceptance, coordinator handling and source read receipts separate.

## 5. Reviewed implementation delivery

- [ ] 5.1 Run affected packaged API/CLI/real-Postgres and repository aggregate tests remotely against the final fresh-main implementation head. Record exact commits/invocations, failed and unrun checks; never use local Bazel fallback.
- [ ] 5.2 Render/validate repository-required Archify source/HTML and portable Lavish OpenSpec, including browser/perceptual checks and durable document delivery when authorized and tooling is available. Do not claim generic HTML as tool validation.
- [ ] 5.3 Complete independent review and authorized draft PR publication with exact-head CI and task/document links under the current custody workflow; do not infer merge/deployment authority.

## 6. Separate operational approvals and retirement

- [ ] 6.1 Obtain separate captain approval and owner readiness for any endpoint, credential, subscription, deployment, production mode change or host integration; execute only the explicitly approved actions.
- [ ] 6.2 Run an approved live shadow/active comparison for a documented representative interval and retain every source ID/disposition, all six classes, failures, legacy/taskless cases, native limitations and accepted/uncertain overlaps. Missing traffic requires approved representative tests, not an empty-window pass.
- [ ] 6.3 Prove signed end-to-end consumer acceptance, retry/rotation/dead-letter recovery and zero lost/duplicate logical escalations, with routine webhook count zero. Clear blockers or record an explicitly approved visible manual workflow for each.
- [ ] 6.4 Obtain a distinct captain decision to pause the exact farm01 inbox-sweep routine only after reviewing the live equivalence packet and elected owner. Proposal/implementation approval does not satisfy this gate.
- [ ] 6.5 Verify authorized pause and rollback/recovery without losing pending records or duplicating accepted work. Preserve all source/triage/outbox/audit/consumer evidence and reopen the gate on regressions.
