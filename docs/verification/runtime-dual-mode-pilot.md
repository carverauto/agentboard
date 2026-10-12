# Two-worker dual-mode pilot (OpenSpec 5.4)

Live run on farm01, 2026-10-12, maintainer-authorized. Server: main 358c8a3
(schema 44) with `AGENTBOARD_MESSAGE_MODE=dual`, Mattermost inbound
(`AGENTBOARD_MATTERMOST_INBOUND_ENABLED=true`,
`AGENTBOARD_MATTERMOST_INBOUND_REPO=carverauto/agentboard`) and private
recipient routes enabled. Workers: `worker-agentboard-farm01-1` (epoch 3) and
`worker-agentboard-farm01-2` (epoch 1), both Pi 0.99.2 exclusive RPC with
`pi-native-v1` and xAI grok-4.3 on host `arrakis`, served by one supervised
`worker serve`. Sends were made headlessly with `agentboard chat send` under
each worker identity by the coordinator, because the Pi exclusive-RPC profile
has no send tool; receipt and handling were done by each recipient's own model.

## Results

| Time (UTC) | Step | Result |
| --- | --- | --- |
| 18:37:26 | Worker 2 → worker 1, private route (`--to`) | Shared bot created worker 1's route channel and posted with `[agent · task]` header and props |
| 18:47:14 | Inbound repository scope added (it was missing from the first dual rollout) | Subscription opened; live stream connected; 8 channels covered |
| 18:47:39–18:47:57 | Worker 1 woken while idle, checks in, marks the `mattermost_inbox` delivery handled by exact ID | Inbox version cleared |
| 18:49:18–18:49:46 | Worker 1 → worker 2, board channel `@mention` (live) | Inbox item within 1 s; worker 2 woken and handled it |
| 18:50:01–18:51:27 | Connector stopped; worker 1 → worker 2 private route sent while down; connector restarted | Item stayed pending with no dispatch while down; delivered and handled 37 s after reconnect |

## Capability matrix (measured here)

| Capability | Pi exclusive RPC worker |
| --- | --- |
| Headless send (channel, private route) | Yes, through `agentboard chat send` (not from inside the model profile) |
| Live inbound to an enrolled recipient | Yes |
| Idle wake for a Mattermost inbox item | Yes |
| Exact handling receipt | Yes |
| Reconnect recovery (connector down) | Yes |
| Body read before handling | Not observed: both models handled the notice from the check-in summary without calling `agentboard_mattermost_read` |
| Catch-up of a post made while inbound was unsubscribed, in an already-joined channel | **No**: the 18:37:25 board-channel mention to worker 2 was never captured, while the same-minute private-route post in a newly discovered channel was. Coverage did not report a gap |

Other harnesses are outside this pilot. Later evidence is in [runtime-harness-readiness.md](runtime-harness-readiness.md).

## Findings

1. Catch-up gap (5.3): a post in an existing bot-joined channel that arrived
   while the inbound owner was not subscribed was not recovered after the owner
   subscribed, and coverage did not expose `catch_up_incomplete`.
2. The Pi wake guidance does not ask the model to read Mattermost bodies before
   handling them.
3. Rollout: dual mode with inbound needs `AGENTBOARD_MATTERMOST_INBOUND_REPO`;
   without it the owner never subscribes and nothing reports that clearly.

## Mattermost outage (OpenSpec 4.3)

Same deployment, 2026-10-12. Mattermost was scaled to zero from 19:13:22 to
19:15:03 UTC (ping 503 during, 200 after).

| Check during the outage | Result |
| --- | --- |
| Board task create and update (`pilot-mm-outage-20261012`) | Succeeded (events 3500, 3501) |
| Worker check-in and `/api/v1/meta` | Succeeded; HTTP 200 |
| `agentboard chat send` | Refused before posting: "retry-key lookup failed; send aborted instead of risking a duplicate" |

After recovery the outbound bridge posted both outage-window lifecycle events at
19:16:00 (about 57 s after Mattermost returned) with no duplicates, and retrying
the aborted send with the same retry key posted exactly once
(`duplicate: false`).
