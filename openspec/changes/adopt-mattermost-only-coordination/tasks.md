# Tasks

Each slice ships alone with its own tests. Run them in this order; nothing is
pre-assigned.

## 1. Coordination channel

- [ ] 1.1 Add server config `AGENTBOARD_MATTERMOST_COORDINATION_CHANNEL_ID` and publish `coordination_channel` in `GET /api/v1/meta`; absent config reports `coordination_channel_unconfigured` as a cutover blocker.
- [ ] 1.2 Generated seat brief: read the coordination channel at check-in (`chat read`) and post claim/PR/blocker/done lines there (`chat send --retry-key`); keep claims and handoffs on the board.
- [ ] 1.3 Seat brief and skills: `context search`/`context feed` before an investigation; `context publish` (FACT/FAIL/OBSERVED/PATCH_SUMMARY with `--task`, HTTPS `--evidence`, stable `--key`) on a root cause, failed approach or landed PR; one coordination-channel chat line citing the entry ID.
- [ ] 1.4 Update the `agentboard`, `agentboard-mattermost` and `ask-user-escalation` skills and the per-harness variants (claude, codex, agy, pi, grok): chat on the coordination channel is the peer channel, `msg send` is legacy.

## 2. Coordinator runner without global enforce

- [ ] 2.1 Accept a verified `coordinator_runner` bearer for the coordinator protocol operations under auth `off`/`observe`; keep anonymous, wrong-scope and non-coordinator callers failing closed. The runner bearer does not authorize decision-conversation routes. Test each mode × credential case.
- [ ] 2.2 Update `docs/coordinator/protocol.md` and the grokbot runbook; prove a live heartbeat/tick/ack from grokbot on farm01 (captain-authorized).

## 3. Herdr seat delivery adapter

- [ ] 3.1 Add a host-scoped unread count per seat for coordination-channel mentions and private-route items. It returns counts only, omits message content, and does not advance `conversation_coverage` or mark anything read. `seat nudge` uses that count and nudges an idle seat that has a non-zero count. `chat read` stays owner-only.
- [ ] 3.2 Report a nudge-pass receipt covering live fleet seats; replace `delivery_adapter_readiness_unverified` with "a covering pass within the staleness window".

## 4. Decision path readiness

- [ ] 4.1 Under auth `off`/`observe`, accept on decision-conversation notify the verified `agent` credential that route already accepts under `enforce`, and on reply the verified `coordinator_participant` credential. Anonymous and wrong-scope callers still fail closed. Show, reconcile and every other non-protocol route stay unchanged.
- [ ] 4.2 Replace `coordinator_decision_path_unavailable_80` with a coordinator protocol heartbeat inside the staleness window plus a retained notify/reply receipt. Do not compare the receipt to the runner credential.

## 5. Legacy unread disposition

- [ ] 5.1 Captain drain report: every unread board direct message grouped by recipient, captain/coordinator first.
- [ ] 5.2 Captain disposition record per board message (`handled`, `forwarded` with a private-route receipt, `kept`), attributed to the captain and stored apart from acknowledgement. `handled` and `kept` leave the message unread and acknowledgeable. Replace `legacy_unread_disposition_unverified_80` with "every unread captain/coordinator DM has a disposition record".

## 6. Cutover

- [ ] 6.1 Remove `@missing_capabilities`; `mattermost` is accepted only when every producer reports ready, and the refusal names the remaining ones. A refused `mattermost` request sets effective mode to `dual` when bridge, private recipient routes and inbound catch-up hold, otherwise `board`. Mirroring follows effective mode. Do not store a last accepted mode.
- [ ] 6.2 Captain-authorized farm01 cutover with a recorded receipt: meta `effective: mattermost`, a legacy `msg send` refused with `message_transport_migrated`, seats coordinating in #agents, a decision relayed by grokbot and answered, and a rollback to `dual` and back.
