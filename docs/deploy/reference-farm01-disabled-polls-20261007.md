# Reconcile farm01's SQL-disabled PR poll states

This is a **post-deployment operator step**, not an automatic migration. It has
not been run against farm01. On 2026-10-07 around 14:45 America/Chicago, emergency
SQL disabled 44 rows without PaperTrail/AshEvents provenance (Agentboard
Context124). Deploy the terminal-polling PR before executing this procedure.
Keep cooperation, fleet automation and the Mattermost bridge off for this rollout.

The incident cohort is the adjacent
[44-ID manifest](reference-farm01-disabled-polls-20261007.txt). Its exact UTF-8
bytes, including the final newline, have SHA256
`d0f10c63a8c9cbb3aced34bad7512de68e7ae6260ad96ab3d2a84f8cb38f28c4`.
These deployment references are not test fixtures. Do not expand the cohort
using a query for every disabled PR: correctly retired PRs are also disabled.

## Review and dry run

1. Record the immutable deployed image digest and release commit containing
   `Polling.reconcile_disabled/3`. Preserve a database backup through the normal
   operator procedure. Copy this manifest into the running release at
   `/tmp/disabled-polls-20261007.txt`; verify its checksum before use.
2. In the release's existing authenticated operator shell, replace the actor
   placeholder below with your registered, full operator ID. Run the following
   through `bin/agentboard rpc` (paste as its expression argument). Use the exact
   release executable path for that container. This does **not** alter flags.

   ```elixir
   bytes = File.read!("/tmp/disabled-polls-20261007.txt")
   digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
   true = digest == "d0f10c63a8c9cbb3aced34bad7512de68e7ae6260ad96ab3d2a84f8cb38f28c4"
   ids = String.split(bytes, "\n", trim: true)
   true = length(ids) == 44 and length(Enum.uniq(ids)) == 44
   actor = %{"agent" => "replace-with-full-operator-id", "model" => "manual", "harness" => "release-rpc"}
   {:ok, rows} = Agentboard.Delivery.Polling.reconcile_disabled(ids, actor, false)
   IO.puts(Jason.encode!(rows))
   ```

3. Review all 44 dispositions against current retained metadata and audit
   history. `merged` is permanently retired; `closed` is retired with a one-hour
   reopen eligibility. Open or unknown lifecycle resumes collection under the
   existing provider budget, without inventing CI evidence. Unknown lifecycle
   needs a provider observation to classify it. A previous successful repair
   reports `already_reconciled`. Rows already resumed by normal reconciliation
   are also audited using their current lifecycle; active reservations must finish.
   Dry run takes bounded row locks but writes no
   poll state, version or event and performs no HTTP request.

Missing canonical/PollState rows or an active reservation rejects the entire
cohort. Stop and investigate; do not
disable rows, clear reservations or write version/event rows with SQL to force
this through. Wait for a legitimate reservation to finish/expire and repeat the
dry run. Do not infer success from an exception or partial console output.

## Apply and verify

After the operator approves the reviewed dry run, repeat the same expression
with only the final `false` changed to `true`. Capture the deployed digest,
operator identity, time and all 44 returned dispositions on the rollout task.
Apply reacquires ordered poll-state locks and rereads state; it
does not reuse a stale dry-run result. Every repaired row goes through the
`reconcile_disabled` Ash action, in one transaction with its PaperTrail version
and AshEvents record. The action advances generation even for a retirement
that leaves `enabled=false`, clears only expired reservation bookkeeping, and
preserves snapshots, lifecycle, head/base, observation time, error and CI state.
An audit failure rolls the whole transaction back.

For each manifest ID, verify a new `delivery_poll_states_versions` row with
`version_action_name='reconcile_disabled'` and the actual operator provenance,
plus the corresponding `board_action_events` PollState action record. Retain
the audit IDs as incident evidence. Read-only SQL may inspect these records;
it must not manufacture the missing history. The new record reconciles the
current state and does not claim the earlier SQL operation was audited.

Repeat the **apply** expression once. All 44 entries must now say
`already_reconciled`, with no further versions/events or generation changes.
The immutable repair-action history is the one-time retry marker, independent
of subsequent normal polling/resume actions. This is not a generic way to undo
future incidents: a later unaudited edit needs a separately reviewed repair.

Observe subsequent scheduler activity: merged PRs make no new requests; closed
PRs become eligible for metadata-only reopen checks after an hour; other rows
resume bounded collection. The 60/minute admission cap and provider cooldown
remain in force. Do not claim successful collection, green CI, or completion of
GH #58 task merge disposition from the repair result alone. Record rollout
verification and any unresolved IDs before closing the incident task.
