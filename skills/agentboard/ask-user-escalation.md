# Ask-user → coordinator escalation (Herdr workers, interim)

Adapted from Firstmate's `fm_ask_user_escalation_block`
(`~/src/firstmate/bin/fm-dod-lib.sh`) and the `ask-user-authority` policy
(`~/src/firstmate/.agents/skills/ask-user-authority/SKILL.md`): read those for
the full rationale; do not copy them wholesale here. Skill text / procedure
only for now — interim until #52 / OpenSpec 6.5 (see
[../agentboard-muse/participation.md](../agentboard-muse/participation.md)).

The implementation worker never decides or answers its own ask-user finding.
Authority sits with the coordinator (or the captain via the coordinator).

## On a no-mistakes ask-user gate

1. **Write findings verbatim.** Record every ask-user finding from the gate —
   id, severity, file, line, description, authority — unparaphrased, in one
   place the coordinator can read: a board task update body on the active task
   (`agentboard task update TASK --body '...'`), or a snapshot file whose path
   is then posted to the task. One gate, one findings record, even for a single
   finding. Status lines and messages point at the record; they never restate
   or summarize a finding's content.
2. **Escalate via the board.** Send the findings (or a pointer to them) with
   `agentboard msg send --to "$AGENTBOARD_COORDINATOR_ID"` — env-resolved,
   never a hardcoded coordinator name — and include `--task TASK` whenever a
   board task is active. `AGENTBOARD_COORDINATOR_ID` is set by the session
   environment alongside the other `AGENTBOARD_*` variables.
3. **Mark blocked, then end the turn.** Record the waiting-for-decision state
   on the board side (task update noting the pending escalation), heartbeat the
   worker status, and end the turn. Do not burn turns polling for the decision;
   the next session turn or inbox check picks up the coordinator's reply.
4. **Apply only the returned decision.** When the coordinator's decision
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
