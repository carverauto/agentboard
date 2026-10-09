# Proposed host admission and receipt contract

Status: implementation checkpoint, not production activation or native readiness. `wake-reservation.schema.json` describes the wake.nudge reservation envelope; seat.restart remains proposed and refused. Strict fields and authenticated canonical references are checked at the API; schema validity alone grants no authority. No credential values, server-selected filesystem paths or executable command text cross this envelope.

## Shared #150 boundary

Board msg1536 from `codex-agentboard-rollout` agrees this as a design recommendation: #156 owns server why/who and canonical subject/version/reason identity; #150 owns host-local admission/probe/journal/safe-input, dry-run/kill-switch and schedule installation. #150 is not designed or landed. Its original card's local-stopgap hashing must be reconciled to the server canonical hash algorithm before cutover. #169 can consume the #156 producer/transport contract rather than invent another wake channel. Captain approval is still required.

Later receipts1607/1611/1622 confirm the missing #150/#123 producers; native
readiness remains unsupported. #169 contract v1 is board document176 at
`/documents/176/download`, SHA256
`79b17c4ca84aa4931a242c0ec67c73323e357ecaf2e5995a40478a6d912deb33`, embedded
`conflict-order-ref-schema`, verified and acknowledged in1674. It freezes
`conflict-order:<order UUID>:<revision>` and the sole Message.id/created_at
identity. The optional exact order_ref v1 uses a 64-hex canonical PR ID; default
ref/tip and evaluated base/ref are distinct. Without #122 election and #169's
canonical currentness resolver, typed conflict orders are unsupported/manual.

## Canonical identity and mutation boundaries

`reason_hash = SHA256(canonical UTF-8 JSON ["agentboard-wake-v1", recipient, normalized owner/repo, reason, source_kind, source_id, source_version])`. String values are literal, ordered exactly as shown, with JSON escaping and no whitespace-dependent hashing. The server computes it and never accepts client attribution as proof of source state. The immutable payload hash covers the entire reserved source-ref set and incarnation/attempt fences using a versioned canonical encoding. Native prompt rendering is a fixed local template with delimited source references; it is not arbitrary remote input or execution authority. Maximum rendered frame is 16 KiB; omitted refs remain pending.

Proposed host API operations are read, reserve, result and reconcile. Read is non-consuming. Reserve requires an existing scoped host credential, fresh canonical source/availability, an exact current incarnation, a caller idempotency key and no unresolved same-recipient effect. Response freezes the schema above with the existing cooperation delivery/batch identity. Runtime route names remain proposed until owner agreement; existing worker APIs do not silently gain new semantics.

Implemented protocol1 routes are GET
`/api/v1/hosts/:host_id/wake-intents/:worker_id` and POST at its
`/reserve`, `/result`, `/reconcile` suffixes. Existing worker wake_intents reads
remain available. Host capability scopes come from enrollment, not attribution
headers or URL choices. Receipt capabilities can inspect/reconcile their current
epoch but cannot reserve or declare transport results.

Reserve fields are exactly intent_id, intent_revision, reason_hash,
enrollment_revision, binding_epoch, session_id, adapter_generation,
idempotency_key. Readiness exposes the enrollment timestamp in UTC microseconds
and current native pane generation. Response includes reservation, the original
cooperation batch and the audited attempt. Same-key retries preserve both frozen
identities; changed content conflicts. A late pending DecisionWake is adopted
under its original source lock, and its route changes atomically before a fallback
watcher can reserve. An already reserved/accepted/uncertain fallback is retained.

Result fields repeat attempt_id, intent_id, reason_hash, payload_hash, recipient,
plus status, bounded reason_codes and evidence_refs. Submitted/not_submitted
require positive references; unknown acceptance is uncertain. Conflicting
committed evidence conflicts. Reconcile repeats only the five immutable fence
fields; historical host reconciliation retains old outcomes without allowing an
old callback to consume the new incarnation. Exact cooperation received/handled
receipts remain separate from source message reads or decision application.

The reservation hash is SHA256 of canonical JSON ordered values
`["agentboard-wake-reservation-v1", intent_id, intent_revision, reason_hash,
worker_id, host_id, repo, enrollment_revision, binding_epoch, session_id,
adapter_generation, cooperation_attempt_id, cooperation_payload_hash,
source_kind, source_id, source_version, delivery_id]`. The client must repeat it;
it must not replace it with the cooperation batch payload hash.

## Admission result

The proposed #150 evaluator returns `{eligible, reason_codes, effect, recipient_fence, native_profile, safe_boundary, dry_run}`. Read-only inspection can report eligible only for shadow comparison; it does not itself authorize native I/O. `native_profile` includes installed server API/version, exact workspace/pane/native session identity, negotiated per-action capabilities and proof reference. `safe_boundary` must attest an atomic compare-and-submit rejection contract for recipient replacement, working/blocked/unknown state, occupied composer and approval UI. Unsupported atomic input yields `safe_input_unproven`, never an unguarded send. The current bundled Herdr schema is static evidence only and contains no composer/recipient-CAS fields on send-text/input/keys.

Before effect: reacquire existing worker/local lock, journal the frozen attempt, revalidate server pause/credential/binding and call the proved atomic native boundary. Filesystem manifest lookups are local allowlisted references, not caller-supplied path strings. Ordinary wake cannot resolve a missing session by spawning.

## Transport result and acknowledgement

Host transport result repeats `intent_id`, `attempt_id`, `reason_hash`, `payload_hash` and the complete expected recipient fence. Its disposition is deferred, refused, not_submitted, submitted or uncertain; reason_codes and evidence references are bounded typed data. Submitted means matching native correlation proves acceptance. Not_submitted requires explicit rejection or proof that native I/O never began. Unknown/lost acceptance is uncertain, including timeout and cancellation after call start. The same result replay is idempotent; conflicting proof must be rejected/preserved for reconciliation.

None of those transport states is a source acknowledgement. The rightful worker separately reads canonical sources, applies an original decision only through its matching native gate/live ownership, and explicitly acknowledges exact delivery/message/decision IDs through the existing credential and receipt APIs. Idle/done does not substitute for handling. One accepted reason hash cannot be prompted again solely because source handling is delayed.

Restart transport uses #164's existing proposed still_alive/known_absent/refused/uncertain/restarted outcomes instead of ordinary wake dispositions. It additionally verifies original episode/attempt/policy, locally preserved lease/STOP brief/WIP/native pipeline custody. New-session proof is transported, not interpreted as permission to apply an answer. Neither this contract nor the static #164 machine activates restart.

## Owning proof surfaces

- Real packaged API/Postgres: canonical hash collision/concurrency, late commit, auth/revoke/pause/epoch races, read not consume, existing answer adoption, fallback bootstrap, exact result and acknowledgement.
- Disposable actual native session: changed occupant/composer/approval rejection, accepted wake, lost result with journal restart, no second input, source acknowledgement distinct from submission.
- #164's later real policy/host integration: preserved seat/lease/WIP, uncertain spawn reconciliation and correlated new-session startup; remain blocked until those dependencies exist.

Mocks/unit tests are useful local contracts but cannot label native safe-input or restart capability ready. No production service, hook, secret activation or old-nudger retirement follows from these interfaces.

Current owner msg1696: #122 worker election returns Event, inbox election returns Message. Document176 sole-Message producer shape is proposed, not an implemented shared return contract. No worker-path typed producer is wired here; currentness/producer readiness remains unsupported until the owner contract is reconciled.
