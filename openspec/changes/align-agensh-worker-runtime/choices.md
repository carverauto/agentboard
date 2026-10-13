# Choices ledger

Final ledger for this change: decisions made where the proposal, design or
specs were silent, checked against the shipped code (v0.3.0). Maintainer
decisions (pilot authorizations, no backups, pre-release publication, task
transfers) are recorded where they were made, not here. Least confident first
within each group.

## Needs a maintainer look

- **The Mattermost task-thread link uses `/_redirect/pl/<root_post_id>`.** It
  is assumed to be a supported Mattermost route. Only URL generation is tested;
  no run has followed the link, because sole-Mattermost mode is still refused.
  The setup doc says the route is unverified. (PR #225)
- **Manual workers have no CLI bind path.** `worker bind` refuses the `manual`
  adapter and `worker serve` never reserves for it, so the 6.5 proofs bound and
  froze batches with an operator script against the published API. A CLI path
  for manual workers is an open follow-up.
- **The spec deltas were narrowed at close to match what shipped.** Herdr
  safe-input rules now cover only Herdr submission of delivery content;
  content-free check-in nudges belong to the seat-nudge capability. "Codex
  foreground checkpoints" became a harness-neutral `manual` fallback. Workers
  enroll with repository scopes only (no goal scope exists). The Muse/AGY
  scenario describes a `manual` binding instead of a Herdr transport.
- **A Mattermost 5xx on `chat send` returns 202 `uncertain` (CLI exit 5)**
  instead of 503, because the post may have landed. Redirects and 429 still
  fail outright. Callers that treated 503 as "safe to resend" must reconcile
  first. (PR #222)
- **Only the worker's own work counts as progress for idle continuation**:
  task updates, links, edits, handoffs, documents and Context entries. Claims
  and renewals do not. The first observation baselines history, so enrollment
  never fires an immediate reminder. (PR #223)
- **Private routes are bot-owned private channels.** Phase 1 has no true DM,
  so each recipient gets one private channel created by the shared bot. A lost
  create is adopted only if it is private and was created by the same bot. Off
  by default. (PR #222)
- **3.4 enablement ran before the proof, not after.** farm01 already had
  observation, cooperation and the bridge enabled when the first-release proof
  ran, so the task's enable-after-proof order was not followed literally.
- **Multi-replica routing (8.1) is proved through shared-PostgreSQL fences**
  (reservations, budgets, wake intents), not by two live Phoenix pods.
- **The pilot coordinator wrote board state as the worker identity.** The Pi
  exclusive-RPC profile has no board tools, so the coordinator performed the
  pilot's claim, PR link and move-on as `worker-agentboard-farm01-1`. Every
  receipt was the worker model's own.
- **Two replaced-epoch pilot attempts were released with captain
  `resolve_attempt`**, accepting possible duplicate notices (Context-only
  batches).

## Sound, low risk

- **No-data-loss for the v0.3.0 rollback test means no table's row count ever
  decreased** across 108 public tables at five stages, plus a canary task that
  survived every stage. Row identity is not compared.
- **Task-linked Context means `task_id` in any repository.** Task repository
  labels are often bare names, so `Context.recent` gained a task-only filter;
  search and feed still require a repository. A Context read failure renders a
  section error, never stale entries. (PR #219)
- **Idle continuation state lives in one `cooperation_continuations` row per
  worker** (schema 44) rather than parsing immutable event keys. Reminders are
  ordinary priority-2 `idle_continuation` events; two no-progress reminders
  start a 1 h cooldown doubling to 4 h; outages start at 15 min;
  `AGENTBOARD_IDLE_CONTINUATION_ENABLED` defaults off. (PR #223)
- **Message history export is NDJSON, 100 per page**, behind
  `meta.message_history`. Only `POST /messages` is refused in `mattermost` mode
  (409 `message_transport_migrated`, CLI exit 4); task orders and handoffs are
  unchanged; pending DMs are not bulk-migrated. (PR #225)
- **Dual-mode notices carry no body.** The board inbox stays authoritative;
  notices captured while routes were off are not replayed when routes turn on.
  (PR #222)
- **"Only `handled` closes an attempt" is taught in the Pi wake text and tool
  description**, not enforced again in server state, because the server already
  enforces it; the defect was the model not being told. (PR #226)
- **Schema numbers were reserved per PR (43, 44)** to avoid migration
  collisions between parallel branches.
- **farm01 config changes were targeted ConfigMap patches**, not full overlay
  applies, because the repository overlay had drifted from the live ConfigMap in
  both directions.
- **`MODULE.bazel.lock` is a no-mistakes protected path**, because pipeline
  steps running Bazel on the operator's Mac commit host-specific digests.
  (PR #228)
