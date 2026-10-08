# Disabled recovery implementation checkpoint

Authority: captain decision `6f947f2e-62ee-4f73-a36b-c44aeb8c4cd6`, task orders1438/1449. Schema31 replaces the withdrawn schema30 assignment.

## Implemented boundary

- `Agentboard.Recovery.readiness/0`: disabled; no operational restart available.
- `Agentboard.Recovery.preview/3`: pure policy/candidate admission contract; caller-supplied policy is a test/integration snapshot, never evidence of captain authorization.
- `Agentboard.Recovery.capture/3`: narrowly authorized internal dry-run capture using DB time and serialized incarnation identity; active capture refuses because the real dependencies are absent. No public endpoint accepts `recovery_internal`; ordinary attribution is not authority.
- `Agentboard.Recovery.Machine`: bounded immutable episode transitions; no shell, network, credentials, task/decision mutation or native child creation. Tests may exercise an active contract snapshot without enabling the persistence boundary.
- Audited Ash episode and attempt resources; immutable version histories, incarnation uniqueness, per-attempt identity/number constraints. Attempts are storage for later integration; this checkpoint's capture produces detected episodes only, never a real intent/attempt.
- Migration20261008003100 preserves higher schema stamps and existing held board/runtime state. Down refuses destructive evidence deletion.

## Follow-up / blocked-on

#154 must supply actual approved policy versions and authority, replacing supplied dry-run policy snapshots. #156 must supply authenticated host enrollment/intents/results, transactional task -> decision -> worker admission, journal/process fencing and real public #141 seat attachment. #155 must turn the reducer's stable escalation identity into one durable human notification independent of coordinator liveness.

No detector scheduling or activation switch is provided here. Native kill/restart, isolated-cwd startup, canonical answer catch-up and exact native gate apply/renew/ack require later real integration proof; these tests only verify the reducer's contract for those inputs. Original claim/decision IDs are retained data, not evidence of a completed native gate. The local nudger remains in service. Services, hooks, secret activation, production enrollment and worker3.4 remain captain-gated.

## Test ownership

`//web:recovery_machine_test` owns bounded lifecycle/protocol logic. `//build/integration:recovery_checkpoint_test` owns packaged dry-run storage, concurrent idempotency, Ash authorization, immutable audit and held-row preservation. Existing `release_schema_test` owns actual migrations from earlier/higher schema and whole-board history compatibility. Fixtures are invented; no production system is restarted or enrolled.
