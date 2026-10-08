# Proposal

## Why

Captain questions remain invisible when seats ask only in prose or use older CLIs, and the existing formal-decision panel sits below the Kanban columns. Surface every outstanding captain question at the top of the board and make filing, recovery and cleanup reliable.

## What Changes

- Move Waiting on captain above the columns, with an exact open count, nav badge, age, oldest-first rows, seat/task/PR links and a compact truthful empty or unavailable state.
- Accept every captain question through positional or existing flag CLI forms, including approval, merge, policy, credential, scope and ask-user gates. Non-gate requests omit gate/findings; ask-user findings remain verbatim and required.
- Make non-gate requests idempotent per task and normalized question, without changing a retained question or silently losing changed options.
- Add capability-aware CLI metadata/doctor diagnostics and a launcher preflight that refuses a seat CLI lacking required decision support, with a verified-release upgrade hint.
- Require decision request plus coordinator notification in every shipped skill/harness overlay. Keep board decision delivery independent of Mattermost.
- Derive read-only unfiled captain asks from authoritative task updates and task-tagged messages; allow explicit owner or authenticated coordinator promotion with provenance and compare-and-set freshness.
- Keep answered items in a collapsed awaiting-ack section; clear terminal requests and retired informal asks. Audit bounded configurable expiry and merged/closed PR cleanup.
- Preserve captain-only answer/recommend/supersede authority, exact answer retry semantics, held claims and existing frozen wake delivery. GH145 policy automation is a separate proposal.

## Capabilities

### New Capabilities

- `captain-decision-intake`: universal filing, normalized retry identity, compatibility preflight, unfiled recovery, top-of-board visibility and audited cleanup.

### Modified Capabilities

None in the main spec inventory (it is currently empty). This proposal explicitly supersedes the *secondary dashboard* placement in the shipped `add-decision-requests` change and extends its API without removing existing request/wake contracts.

## Impact

Go CLI/client/seat preflight; Phoenix Decisions, BoardLive, DecisionPanel and navigation; shipped skills and setup docs; existing integration fixtures. Planning only: no runtime code, migration, enrollment, credentials or deployment changes in this deliverable. The display is derived; durable new kinds and expiry may need a small additive migration after captain approval and coordinator allocation. The task's suggested schema29 conflicts with pending PR140's proof29; no number is reserved by this proposal. Remote proof and native no-mistakes without --yes govern later implementation/publication; the agent never merges.
