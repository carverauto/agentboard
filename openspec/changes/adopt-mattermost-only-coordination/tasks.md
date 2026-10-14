# Tasks

Each slice ships alone with its own tests. Run them in this order; nothing is
pre-assigned.

## 1. Coordination channel

- [ ] 1.1 Add server config `AGENTBOARD_MATTERMOST_COORDINATION_CHANNEL_ID` and publish `coordination_channel` in `GET /api/v1/meta`; absent config reports `coordination_channel_unconfigured` as a cutover blocker.
- [ ] 1.2 Generated seat brief: read the coordination channel at check-in (`chat read`) and post claim/PR/blocker/done lines there (`chat send --retry-key`); keep claims and handoffs on the board.
- [ ] 1.3 Seat brief and skills: `context search`/`context feed` before an investigation; `context publish` (FACT/FAIL/OBSERVED/PATCH_SUMMARY with `--task`, HTTPS `--evidence`, stable `--key`) on a root cause, failed approach or landed PR; one coordination-channel chat line citing the entry ID.
- [ ] 1.4 Update the `agentboard`, `agentboard-mattermost` and `ask-user-escalation` skills and the per-harness variants (claude, codex, agy, pi, grok): chat on the coordination channel is the peer channel, `msg send` is legacy.

## 2. Coordinator runner without global enforce

- [ ] 2.1 In `AgentboardWeb.Plugs.AgentAuth`, under auth `off` and `observe`, verify a presented bearer and assign `authenticated_agent` for the four coordinator protocol operations, including GET tick and GET show, and for decision-conversation notify and reply. No bearer stays anonymous. A missing, invalid or revoked bearer fails closed and assigns nothing. Do not add this path to decision-conversation show, reconcile, or any other route; those routes keep their current authentication. The four protocol operations accept that principal when it is the active coordinator's `coordinator_runner`, including the domain check that today requires `enforce`. Wrong-scope callers still fail closed. The runner bearer does not authorize notify or reply. Test `off` and `observe`, including GET tick.
- [ ] 2.2 Update `docs/coordinator/protocol.md` and the grokbot runbook; prove a live heartbeat/tick/ack from grokbot on farm01 (captain-authorized).

## 3. Herdr seat delivery adapter

- [ ] 3.1 Add a host-scoped unread count per seat for coordination-channel mentions and private-route items. It returns counts only, omits message content, and does not advance `conversation_coverage` or mark anything read. `seat nudge` uses that count and nudges an idle seat that has a non-zero count. `chat read` stays owner-only.
- [ ] 3.2 Report a nudge-pass receipt covering live fleet seats; replace `delivery_adapter_readiness_unverified` with "a covering pass within the staleness window".

## 4. Decision path readiness

- [ ] 4.1 Decision-conversation notify and reply accept the `authenticated_agent` assigned in 2.1 under auth `off` and `observe`: `agent` for notify, `coordinator_participant` for reply, including the domain check that today requires `enforce`. Anonymous and wrong-scope callers still fail closed. Show and reconcile keep their current authentication.
- [ ] 4.2 Replace `coordinator_decision_path_unavailable_80` with a coordinator protocol heartbeat inside the staleness window plus a retained notify/reply receipt. Do not compare the receipt to the runner credential.

## 5. Legacy unread disposition

- [ ] 5.1 Captain drain report: every unread board direct message grouped by recipient, captain/coordinator first.
- [ ] 5.2 Captain disposition record per board message (`handled`, `forwarded` with a private-route receipt, `kept`), attributed to the captain and stored apart from acknowledgement. `handled` and `kept` leave the message unread and acknowledgeable. Replace `legacy_unread_disposition_unverified_80` with "every unread captain/coordinator DM has a disposition record".

## 6. Cutover

- [ ] 6.1 Remove `@missing_capabilities`; `mattermost` is accepted only when every producer reports ready, and the refusal names the remaining ones. A refused `mattermost` request sets effective mode to `dual`, including when bridge, private routes or inbound are unready. Dual has no activation gate. Invalid requested modes stay `board`. Mirroring follows effective mode. Do not store a last accepted mode.
- [ ] 6.2 Captain-authorized farm01 cutover with a recorded receipt: meta `effective: mattermost`, a legacy `msg send` refused with `message_transport_migrated`, seats coordinating in #agents, a decision relayed by grokbot and answered, and a rollback to `dual` and back.
