# Implementation authorization

Captain decision `6f947f2e-62ee-4f73-a36b-c44aeb8c4cd6` was answered on behalf of captain on 2026-10-08 at 19:01:13Z (14:01 CT), following the captain 14:00 CT decision. Retained board answer and task orders are messages 1393 and 1394. The approved planning checkpoint is `8590a5738b7b1d7683c95b9abf8fa59616ae7a1a`.

The proposal is approved for implementation with minimum 600-second stale age, `max(600, 3 * declared cadence)` admission, explicit cadence opt-in (recommended at most 120 seconds), three attempts, 60/300-second retry delays, a 180-second host/startup deadline, and final `escalate_preserve`. Claims, decisions and uncertain effects remain retained; no automatic release, supersede or reassignment is authorized.

Policy activation, services/hooks/secrets and production/fleet rollout require separate captain decisions. Worker runtime enrollment step 3.4 remains held until #156/#164 land. Publish through native No-mistakes without `--yes`; never merge.

This authorization is applied by entering the implementation workflow and retaining its defaults and boundaries. It is not runtime readiness, completed implementation, or deployment evidence. Task 1.1 remains pending until dependency interfaces and their fixtures are agreed and verified.

## Coordinator implementation checkpoint orders

Task orders 1438 (2026-10-08 19:56:57Z) and corrected 1449 (20:01:15Z) authorize the current PR as a disabled recovery resources/episode-machine checkpoint. The schema reservation is **31**, migration `20261008003100`, with `GREATEST(version,31)`. The earlier schema-30 assignment was withdrawn; 29 and 30 belong to other seats.

This checkpoint does not own full #154 policy-store, #155 escalation transport, or broader #156 host-intent delivery. Narrow prerequisite types may support honest compilation and contract tests; they are not readiness or deployed integration. End-to-end native kill/restart and retained-answer application proof are blocked on those real dependencies. Public #141 seat attachment merged in PR167 and remains the sole seat interface. All activation, service/hook/secret steps and worker runtime 3.4 remain held.
