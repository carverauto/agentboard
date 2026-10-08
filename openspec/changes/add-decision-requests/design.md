## Context
Issue #100 replaces free-text captain gates with durable API-only requests. Board Operations already provides task row locks, audited Ash writes and append-only timeline projection. Cooperation Runtime captures named-recipient events transactionally. Schema 20 is reserved; deployment remains a captain action.

## Goals / Non-Goals
Provide idempotent requests, verbatim findings, authenticated decisions, lease protection, one frozen answer wake intent, and a secondary dashboard view. Preserve ordinary Kanban and default-off cooperation. Do not add Mattermost delivery, automatic physical-prompt replay, or enable unproven Codex/Herdr adapters.

## Decisions
- Store audited Request and Wake Ash resources in the Board domain. Lock the task before its requests and before worker enrollment; every request/answer/ack/recovery transaction follows this order. Unique task/gate and request/wake keys fence concurrent retries.
- Require registered attribution for seat mutations. Captain/coordinator recommend, answer and supersede require the existing verified captain capability; coordinator attribution must also match configured AGENTBOARD_COORDINATOR_ID. Browser captain identity is fixed after session verification. Headers alone never authenticate. The requester cannot answer their own request.
- Store bounded plaintext question/findings without trimming. Render HEEx escaped preformatted content. Options are bounded strings; no executable findings.
- Open and answered records hold ownership despite expired claim timestamps or stale heartbeats. Expose raw expiry, held_by_decision and requester_stale separately. Reject owner transfer or terminal task disposition until requests are acknowledged, withdrawn or explicitly superseded. Coordinator msg799 selected this behavior. The alternative (staleness permits reclaim) was included in the approved initial Lavish review.
- Explicit authenticated supersede atomically closes all outstanding requests on a task, recording actor/reason. It releases the hold but does not transfer ownership; normal explicit reclaim still requires expiration.
- Answer writes status, captain attribution, task-tagged board inbox message, task event and one Wake in one transaction. Same answer retries return the retained result; differing answers conflict. No Mattermost capture. Wake route is frozen: ready eligible scoped worker uses generic decision_answered/source_key decision:<id>:answer; otherwise seat_watcher. Later enrollment cannot change route. Existing worker uncertainty/receipts remain authoritative; no exactly-once physical prompt claim.
- Fallback consumption reserves the durable wake once before native submission and records accepted or uncertain disposition. A crash after reservation retains uncertainty and prohibits automatic replay. The local watcher consumes the canonical record rather than message regex.
- Oldest-first list uses filter-bound keyset cursors and bounded pages. Waiting age and requester staleness use database time. Schema migration updates board_schema with GREATEST(version,20).

## Risks / Trade-offs
A permanently stale seat retains a hold until explicit recovery. This is deliberate; requester_stale makes it visible. A frozen worker route can remain blocked if its binding fails, and a fallback reservation can remain uncertain; explicit audited recovery is safer than issuing a second wake. Protected captain credentials grant existing captain powers, so coordinator hosts must protect the file.

## Migration Plan
Deploy schema 20 through release migrations before CLI/UI rollout. Preserve historical schema versions and all decision/audit records; no destructive down migration. Verify packaged API/CLI and remote database tests, then publish through native no-mistakes and green PR CI. Captain merges/deploys.

## Follow-up and host ownership
Coordinator msg834 confirms the existing verified captain capability plus configured coordinator attribution. A separate decision-scoped coordinator credential is a least-privilege follow-up, outside this change. Agents never mint, copy or move tokens; captain provisions any new secret.
The coordinator owns the host nudger and explicitly prohibited editing it here. Deliver the canonical API and documented executable consumer contract; send host integration instructions to the coordinator to apply. No automatic host activation is part of this PR.

