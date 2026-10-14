# Tasks

Each slice ships alone with its own tests. Run them in this order; nothing is
pre-assigned.

## 1. Coordination channel

- [ ] 1.1 Add server config `AGENTBOARD_MATTERMOST_COORDINATION_CHANNEL_ID` and publish `coordination_channel` in `GET /api/v1/meta`; absent config reports `coordination_channel_unconfigured` as a cutover blocker.
- [ ] 1.2 Generated seat brief: read the coordination channel at check-in (`chat read`) and post claim/PR/blocker/done lines there (`chat send --retry-key`); keep claims and handoffs on the board.
- [ ] 1.3 Seat brief and skills: `context search`/`context feed` before an investigation; `context publish` (FACT/FAIL/OBSERVED/PATCH_SUMMARY with `--task`, HTTPS `--evidence`, stable `--key`) on a root cause, failed approach or landed PR; one coordination-channel chat line citing the entry ID.
- [ ] 1.4 Update the `agentboard`, `agentboard-mattermost` and `ask-user-escalation` skills and the per-harness variants (claude, codex, agy, pi, grok): chat on the coordination channel is the peer channel, `msg send` is legacy.

## 2. Coordinator runner without global enforce

- [ ] 2.1 Accept a verified `coordinator_runner` bearer for the coordinator protocol operations under auth `off`/`observe`; keep anonymous, wrong-scope and non-coordinator callers failing closed, and leave every other route unchanged. Test each mode × credential case.
- [ ] 2.2 Update `docs/coordinator/protocol.md` and the grokbot runbook; prove a live heartbeat/tick/ack from grokbot on farm01 (captain-authorized).

## 3. Herdr seat delivery adapter

- [ ] 3.1 `seat nudge` counts unread coordination-channel mentions of the seat ID and private-route items (existing `chat read` cursor), and nudges an idle seat that has them.
- [ ] 3.2 Report a nudge-pass receipt covering live fleet seats; replace `delivery_adapter_readiness_unverified` with "a covering pass within the staleness window".

## 4. Decision path readiness

- [ ] 4.1 Replace `coordinator_decision_path_unavailable_80` with measured coordinator protocol liveness plus a retained decision conversation notify/reply receipt newer than the runner credential.

## 5. Legacy unread disposition

- [ ] 5.1 Captain drain report: every unread board direct message grouped by recipient, captain/coordinator first.
- [ ] 5.2 Captain disposition actions (handled, forwarded to the private route with a receipt, kept); replace `legacy_unread_disposition_unverified_80` with "no undisposed captain/coordinator DM".

## 6. Cutover

- [ ] 6.1 Remove `@missing_capabilities`; `mattermost` is accepted only when every producer reports ready, and the refusal names the remaining ones.
- [ ] 6.2 Captain-authorized farm01 cutover with a recorded receipt: meta `effective: mattermost`, a legacy `msg send` refused with `message_transport_migrated`, seats coordinating in #agents, a decision relayed by grokbot and answered, and a rollback to `dual` and back.
