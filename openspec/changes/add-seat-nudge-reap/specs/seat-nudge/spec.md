# Seat nudge and reap

## Purpose

Wake idle Herdr-hosted seats that have board work, and close seats that have
finished, without writing to the board or granting authority.

## ADDED Requirements

### Requirement: Seat discovery by pane name
The CLI SHALL treat a Herdr agent pane as a seat only when its name equals a non-retired board agent ID, exactly one pane has that name, and the pane's agent kind equals the identity's harness. It SHALL skip and report every other named pane.

#### Scenario: Duplicate or mismatched pane
- **WHEN** two panes share a name, or a pane named for a codex identity runs another agent
- **THEN** neither is nudged or reaped and each is reported as skipped with the reason

#### Scenario: Registration names the pane
- **WHEN** an agent registers with `--backend herdr` inside a Herdr pane
- **THEN** the CLI renames that pane to the agent ID, warning without failing if Herdr refuses

### Requirement: Reasoned nudge of idle seats only
The nudge SHALL prompt a seat only when Herdr reports it idle or done, its recent screen shows no work in progress, its availability is unset or active, and it has a reason: unread messages, an expired claim on in-progress work, a higher-priority owned task than its current work, or idleness past `idle_after` with in-progress work.

#### Scenario: Busy or blocked seat
- **WHEN** a seat is working, shows a working indicator, has an approval prompt open, or reports unknown status
- **THEN** it is not prompted

#### Scenario: Waiting seat
- **WHEN** a seat owns a blocked or review task whose latest note says it waits on the captain or coordinator
- **THEN** it is prompted only about messages that arrived after it began waiting, and never pointed at new work

### Requirement: Recipient recheck and no replay
Before sending, the nudge SHALL re-read the pane and abort if its name, native session ID, agent kind or state sequence changed, if it left idle/done, or if its screen shows work in progress. It SHALL NOT send the same reason set twice, SHALL respect `min_gap`, and SHALL record an uncertain send without replaying it.

#### Scenario: Session replaced before send
- **WHEN** the pane's native session ID differs at recheck
- **THEN** no prompt is sent and the decision is reported as aborted

#### Scenario: Uncertain send
- **WHEN** the prompt command fails for any reason other than Herdr's agent_blocked rejection
- **THEN** the reason set is recorded as sent and is not retried

### Requirement: Conservative reap
Reap SHALL close a seat's pane only after it has been idle for `reap_after` with no open owned task, no unread message, a landed checkout and an availability that is unset or active, and only if a recheck shows the same pane name, native session, agent kind, state sequence and idle/done status with no busy indicator on screen. It SHALL return a Treehouse lease only for configured pool roots, when the holder has no live pane, no open task, no process in the worktree and landed work. It SHALL NOT release claims or retire identities.

#### Scenario: Unlanded work
- **WHEN** a finished seat's checkout has uncommitted changes or a HEAD on no remote branch
- **THEN** its pane and lease are kept and the reason is reported

#### Scenario: Expired claim of an absent seat
- **WHEN** an identity with no live pane holds an expired claim
- **THEN** reap reports it and leaves the claim unchanged

### Requirement: Dry run, kill switch and single run
Both commands SHALL change nothing without `--apply`, SHALL do nothing while the configured kill-switch file exists, and SHALL skip when another run holds the state lock.

#### Scenario: Default invocation
- **WHEN** an operator runs `agentboard seat nudge` without `--apply`
- **THEN** the report lists every would-be prompt and no prompt is sent and no state is saved
