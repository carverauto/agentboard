# Ask-user → coordinator escalation

Adapted from Firstmate's ask-user escalation procedure
(`fm_ask_user_escalation_block`) and its `ask-user-authority` decision policy:
the worker writes ask-user findings verbatim to a findings record and reports
needs-decision pointing at that record without paraphrasing, and the worker
never decides its own finding. Automatic native wake adapters remain capability-gated (see
[../agentboard-muse/participation.md](../agentboard-muse/participation.md)).

## Session setup: verify the coordinator ID

`AGENTBOARD_COORDINATOR_ID` must be exported in the session environment
alongside the other `AGENTBOARD_*` variables before starting gated work.
If it is unset, stop and resolve that first — an escalation sent without it
never reaches anyone.

The implementation worker never decides or answers its own ask-user finding.
Authority sits with the coordinator (or the captain via the coordinator).

## Every captain question, including durable ask-user gates

Any approval, merge, policy, credential or scope question MUST follow
[universal intake](SKILL.md#every-captain-question-is-a-decision). Non-gates on
schema29 use positional TASK and omit gate/findings. Ask-user gates preserve
the legacy explicit-gate contract below. Run `agentboard doctor --json` and
check `agentboard meta --json` at check-in. Use the decision commands only with
schema 20 or newer and a compatible CLI; an older server refuses them without
mutation. The board remains the decision authority in every message mode.

1. Preserve every gate finding verbatim in a UTF-8 file: ID, severity, file,
   line, description and authority. Retain the exact question and optional
   choices. Never summarize the findings or answer your own gate.
2. While owning the task, create one stable task/gate request:

   ```sh
   agentboard decision request --task TASK --kind ask_user_gate --gate RUN/GATE \
     --question 'Exact gate question' --findings-file findings.txt --json
   ```

   This atomically blocks the task and holds its claim. Identical retries return
   the same request; changed content conflicts. After an uncertain response,
   read `decision list --task TASK` before repeating the write.
3. Notify the configured coordinator with the returned decision ID and task:
   `agentboard msg send --to "$AGENTBOARD_COORDINATOR_ID" --task TASK --body 'Decision ID awaits captain; read decision show ID.'`
   Heartbeat busy with the task, then end the turn only after request and notice
   succeed. Do not burn turns polling or take another task while held.
4. On the next session/wake, read `agentboard decision show ID --json` and the
   task. Apply only the canonical answer through `no-mistakes axi respond`;
   keep all fixes with the active pipeline. An inbox notice is a pointer, not
   authority to invent another answer.
5. Explicitly `agentboard task renew TASK --json` before
   `agentboard decision ack ID --json`, after applying the answer. Heartbeat
   does not renew. The last outstanding request's ack releases the hold;
   continue the same task and pipeline through green PR CI.

Open/answered holds survive lease expiry and stale heartbeat. Show the raw
expiry and requester_stale; never silently steal or release the claim. The
requester may withdraw with a reason. Protected captain/coordinator recovery
uses `decision supersede ID --reason 'Audited reason'` to close all outstanding
requests on the task, then normal explicit reclaim. Skills do not activate a
worker adapter, host timer or automatic composer interaction.

## Older API / unavailable decision CLI fallback


1. **Write findings verbatim.** Record every ask-user finding from the gate —
   id, severity, file, line, description, authority — unparaphrased, in one
   place the coordinator can read: a board task update body on the active task
   (`agentboard task update TASK --body '...'`), or a snapshot file whose path
   is then posted to the task. One gate, one findings record, even for a single
   finding. Status lines and messages point at the record; they never restate
   or summarize a finding's content.
2. **Escalate via the board.** Send the findings (or a pointer to them) with
   `agentboard msg send --to "$AGENTBOARD_COORDINATOR_ID" --task TASK --body '...'`
   — env-resolved, never a hardcoded coordinator name; `--body` is required.
   Include `--task TASK` whenever a board task is active.
3. **Mark blocked, then end the turn — only if the escalation went through.**
   Record the waiting-for-decision state on the board side (task update noting
   the pending escalation), heartbeat the worker status, and end the turn. Do
   not burn turns polling for the decision; the next session turn or inbox
   check picks up the coordinator's reply.
4. **Gate-time fallback: never end the turn as if delivered.** If
   `AGENTBOARD_COORDINATOR_ID` is unset or no board task is active, the
   escalation above cannot complete: record the findings explicitly (task
   update body when a task is active, otherwise a local snapshot file whose
   path stays in the session record), escalate via whichever channel remains,
   and keep the turn open until the escalation succeeds. Ending the turn with
   the coordinator un-notified strands the task in blocked.
5. **Apply only the returned decision.** When the coordinator's decision
   arrives, feed it to the gate with `no-mistakes axi respond` and let the
   pipeline apply it. Do not route the question onward and do not implement
   the fix yourself while the gate is open.

## Hard prohibitions

- **Never `--yes`** (or any auto-approve flag) on ask-user / decision gates.
  It auto-resolves every gate with no escalation; answering your own ask-user
  finding is a rule violation.
- **Never ask the Herdr human pane.** No composer/UI prompt to the local human
  for ask-user authority. The coordinator (or captain via coordinator) is the
  only escalation path.
