# First-release pilot: red CI reaches its idle owner (OpenSpec 3.2/3.3)

Live run on farm01, 2026-10-12, maintainer-authorized. Server: main c39b9c7
(schema 42), observation, cooperation and the outbound bridge enabled. Worker:
`worker-agentboard-farm01-1`, Pi 0.99.2 exclusive RPC with `pi-native-v1`,
xAI grok-4.3, host `arrakis`, supervised by the `worker install` LaunchAgent.
The Pi profile has only the dedicated check-in and ack tools, so the board writes
that set up the scenario (claim, PR link, moving on) were made by the
coordinator acting as the worker identity. Every receipt below was made by the
worker's own model through `agentboard_ack`.

## Timeline (UTC)

| Time | Event |
| --- | --- |
| 15:55:24 | Pilot task `pilot-ci-red-20261012` assigned to and claimed by the worker |
| 15:55:47 | Worker links draft PR #224 (deliberate shellcheck SC2086 in a required `lint` path), moves the task to review and claims `pilot-ci-next-20261012` |
| 15:56:10 | Required `lint` check fails on head 89b0c49b |
| 15:57:08 | Server records the failure episode and repair task `ci-repair-0519cdc3…`, assigned to the worker |
| 15:57:25 | Obligation `0519cdc3…` unresolved and a `ci_failure` delivery pending for the worker (about 75 s after the failure) |
| 16:12–16:22 | After the session replacement below, the idle Pi session is woken through the native idle-wake path; the model handles 102 deliveries (94 backlog Context notices, the CI alert, reminder 1 and task events) by exact ID across 10 attempts, stating each time that CI repair stays open |
| 16:28:22 / 16:28:32 | Reminder 2 dispatched / handled by exact ID |
| 16:44, 16:59 | Reminders 3 and 4 (15-minute cadence, no progress recorded) |
| 17:00:00 | Obligation escalated to the captain after four reminders in the hour |
| 17:09–17:20 | Repair pushed; an empty-diff repair left the path-filtered required checks unreported and the obligation stayed `degraded`, never green; a passing in-path change ran them |
| 17:26:22 | All required checks green on the current head; obligation resolved. The repair task stays `assigned`: green CI does not complete it |
| 17:26:48–17:27:30 | Live pause blocks the adapter (`paused`); resume returns it to healthy/ready |

## Restart, stale epochs and no replay (3.3)

- Epoch 1 → 2: the 2026-10-08 binding's session no longer existed. Rebind
  marked its in-flight attempt `uncertain` (`binding_replaced`); the server kept
  it active, and only a captain `resolve_attempt` retry decision released it.
- Epoch 2 → 3: the connector and Pi session were restarted mid-obligation to
  load the handled-guidance fix. The host kept its crash journal for the epoch-2
  attempt and reported it as unresolved historical evidence without replaying it
  until the captain decision.
- A `handled` ack for an epoch-2 delivery from the epoch-3 session was refused
  ("receipt IDs must be unique members of the frozen attempt").
- No task lease was recovered or reassigned automatically: both pilot tasks
  kept their worker claims, and the repair task stayed assigned throughout.

## Defects found and fixed

- PR #226: the Pi wake text and `agentboard_ack` description did not say that
  only `handled` closes an attempt; the model acknowledged `received` and the CI
  alert queued behind the open attempt. The host also reported a replaced-epoch
  attempt as "invalid frozen worker batch"; it now names the attempt and the
  captain `resolve_attempt` endpoint.
- Stopping the Pi session with Ctrl-C leaves its socket; the next session's
  adapter refuses takeover until the stale socket is inspected and removed.
  Still open; the restart script performed the inspection.

## Not covered

macOS Pi worker only; other harnesses are tracked in 6.3–6.5. The worker
initially ran a fix-branch build (6241037), then main 358c8a3
(darwin arm64 sha256 `2b91a31201cea3dccc9e2fd38250e9f9cd35c85735ba7332de9ef6aee9ffec2c`).
