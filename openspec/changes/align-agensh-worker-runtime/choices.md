# Choices ledger

Decisions made while implementing this change where the proposal, design or
specs were silent. Each entry says what was chosen, why, and how confident the
implementer is. Entries marked **provisional** are revisited before the change
closes.

## Needs a maintainer look

- **5.2 send failure semantics changed.** A Mattermost 5xx on `chat send` now
  returns 202 `uncertain` (exit 5) instead of 503, because the post may have
  landed. Redirects and 429 still fail outright. Callers that treated 503 as
  "safe to resend" must now reconcile first. (PR #222)
- **5.1 private routes are bot-owned private channels.** Phase 1 has no true
  DM, so each recipient gets one private channel created by the shared bot. A
  lost create is adopted only if it is private and was created by the same bot.
  Off by default. (PR #222)
- **6.6 progress definition.** Only the worker's own task updates, links,
  edits, handoffs, documents and Context entries count as progress; claims and
  renewals do not. First observation baselines history, so enrollment never
  fires an immediate reminder. (PR #223)
- **Pilot board writes as the worker identity.** The Pi exclusive-RPC profile
  has no board tools, so the coordinator performed the pilot's claim, PR link
  and move-on as `worker-agentboard-farm01-1`. All receipts were the worker
  model's own. Recorded in the pilot evidence. (3.2)
- **Captain retry decisions during the pilot.** Two replaced-epoch attempts
  (Context-only batches) were released with `resolve_attempt` under the
  maintainer's pilot authorization, accepting possible duplicate notices.

## Sound, low risk

- **6.2 task-linked means `task_id`, any repository.** Task repo labels are
  often bare names, so `Context.recent` gained a task-only filter; search and
  feed still require a repository. Full list at `/context?task=ID`. A Context
  read failure renders a section error, never stale entries. (PR #219)
- **6.6 state lives in a new `cooperation_continuations` row per worker**
  (schema 44) rather than parsing immutable event keys; reminders are ordinary
  priority-2 `idle_continuation` events; two no-progress reminders start a 1 h
  cooldown doubling to 4 h; outage dispositions start at 15 min; feature flag
  `AGENTBOARD_IDLE_CONTINUATION_ENABLED` defaults off. (PR #223)
- **7.2 export is NDJSON**, 100 per page, behind `meta.message_history`; only
  `POST /messages` is refused in `mattermost` mode (409
  `message_transport_migrated`, CLI exit 4); task orders and handoffs are
  unchanged; no bulk migration of pending DMs. (PR #225)
- **7.2 task-thread link uses `/_redirect/pl/<root_post_id>`.** Assumed to be a
  supported Mattermost route; only URL generation is tested. **Provisional:**
  confirm in the 5.4 live run.
- **5.1 notices carry no body.** The board inbox stays authoritative; notices
  captured while routes were off are not replayed when routes turn on. (PR #222)
- **Handled guidance lives in the Pi wake text and tool description**, not in
  server state, because the server already enforces that only `handled` closes
  an attempt; the defect was the model not being told. (PR #226)
- **Schema numbers reserved per PR (43, 44)** to avoid migration collisions
  between parallel branches.
- **farm01 rollouts without a pre-migration backup**, by maintainer decision
  for pre-release data; farm01 has no CNPG object store. Recorded in the
  rollout record.
- **Config changes on farm01 by targeted ConfigMap patch**, not a full overlay
  apply, because the repository overlay had drifted from the live ConfigMap in
  both directions.
- **`MODULE.bazel.lock` is a no-mistakes protected path**, because pipeline
  steps running Bazel on the operator's Mac commit host-specific digests.
