defmodule Agentboard.Delivery.Duplicates do
  @moduledoc "Possible duplicate findings, once-only inbox receipts and explicit owner decision requests."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Agent, Task}
  alias Agentboard.Delivery.{DuplicateFinding, PullRequest}
  alias Agentboard.Repo
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}

  # Caller owns a separate reconciliation transaction, never a PollState lock.
  # Task -> finding -> message is the only additional lock order. No provider I/O.
  def reconcile(id) do
    if Agentboard.Delivery.Scheduling.enabled?() do
      host = host(id)
      if host, do: Ops.lock_task(host.id)
      <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "agentboard-duplicate:" <> id)
      Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])
      existing = Ash.get!(DuplicateFinding, id, not_found_error?: false)
      finding = existing || record(id)
      if finding, do: notify(finding, host && Ash.get!(Task, host.id))
      not is_nil(finding) and is_nil(existing)
    else
      false
    end
  end

  defp record(id) do
    # Only matching, fenced current open metadata is a candidate. The original
    # proof is an immutable merged snapshot, independent of freshness/CI green.
    %{rows: rows} = Repo.statement!("""
      SELECT old.pull_request_id,old.id,current.id,
        CASE WHEN old.payload->>'head_repo'=current.payload->>'head_repo'
          AND old.payload->>'head_ref'=current.payload->>'head_ref'
          AND nullif(current.payload->>'head_repo','') IS NOT NULL
          AND nullif(current.payload->>'head_ref','') IS NOT NULL
          THEN 'head_branch' ELSE 'task_submission' END AS basis
      FROM delivery_pull_requests pr
      JOIN delivery_poll_states ps ON ps.id=pr.id AND ps.lifecycle='open'
      JOIN delivery_ci_snapshots current ON current.id=ps.snapshot_id
        AND current.pull_request_id=ps.id AND current.lifecycle='open'
        AND current.head_sha=ps.head_sha AND current.base_sha=ps.base_sha
      JOIN delivery_ci_snapshots old ON old.lifecycle='merged' AND old.pull_request_id<>pr.id
      JOIN delivery_pull_requests original ON original.id=old.pull_request_id
        AND original.owner=pr.owner AND original.repo=pr.repo
      WHERE pr.id=$1 AND (
        (nullif(current.payload->>'head_repo','') IS NOT NULL
         AND nullif(current.payload->>'head_ref','') IS NOT NULL
         AND old.payload->>'head_repo'=current.payload->>'head_repo'
         AND old.payload->>'head_ref'=current.payload->>'head_ref')
        OR EXISTS(SELECT 1 FROM delivery_task_links a JOIN delivery_task_links b ON b.task_id=a.task_id
          WHERE a.pull_request_id=pr.id AND b.pull_request_id=old.pull_request_id))
      ORDER BY basis,old.observed_at,old.id LIMIT 1
      """, [id])
    case rows do
      [[original, merged_snapshot, snapshot, basis]] ->
        Ops.create(DuplicateFinding, :record, %{
          id: id, merged_pull_request_id: original, basis: basis,
          snapshot_id: snapshot, merged_snapshot_id: merged_snapshot,
          created_at: Ops.now(), notified_recipients: %{}
        }, @actor)
      [] -> nil
    end
  end

  defp host(id) do
    %{rows: rows} = Repo.statement!("""
      SELECT t.id FROM tasks t JOIN delivery_task_links l ON l.task_id=t.id
      WHERE l.pull_request_id=$1 AND t.status IN ('in_progress','blocked','review')
        AND t.assignee_id IS NOT NULL
      ORDER BY l.recorded_at,t.id LIMIT 1
      """, [id])
    case rows do
      [[task]] -> Ash.get!(Task, task)
      [] -> nil
    end
  end

  defp live?(%Task{status: status, assignee_id: owner}),
    do: status in ~w(in_progress blocked review) and not is_nil(owner)
  defp live?(_), do: false

  defp notify(finding, task) do
    if Application.get_env(:agentboard, :cooperation_enabled, false) do
      coordinator = Application.get_env(:agentboard, :coordinator_id)
      recipients = [if(live?(task), do: task.assignee_id), coordinator]
      recipients = recipients |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
      receipts = Enum.reduce(recipients, finding.notified_recipients, fn recipient, receipts ->
        if Map.has_key?(receipts, recipient) or is_nil(Ash.get!(Agent, recipient, not_found_error?: false)) do
          receipts
        else
          projection = project(finding, task)
          body = "Possible duplicate PR: #{projection["url"]} may repeat merged #{projection["merged_url"]} (#{finding.basis}). " <>
            "Finding retained; no PR closed, decision created, task assigned or lease changed. " <>
            if(projection["decision_cta"], do: "Live owner can request captain disposition: #{projection["decision_cta"]["command"]}", else: "No live duplicate-card owner; coordinate explicitly.")
          message = Ops.send_message(@actor, %{"to" => recipient, "task" => if(live?(task), do: task.id), "body" => body}, Ops.now())
          Map.put(receipts, recipient, message.id)
        end
      end)
      if receipts != finding.notified_recipients,
        do: Ops.update(finding, :notify, %{notified_recipients: receipts}, @actor)
    end
  end

  def projection(id) do
    case Ash.get!(DuplicateFinding, id, not_found_error?: false) do
      nil -> nil
      finding -> project(finding, host(id))
    end
  end

  defp project(finding, task) do
    duplicate = Ash.get!(PullRequest, finding.id)
    original = Ash.get!(PullRequest, finding.merged_pull_request_id)
    cta = if live?(task), do: %{
      "task_id" => task.id, "owner_id" => task.assignee_id,
      "command" => "agentboard pr duplicate-decision #{finding.id} --task #{task.id}"
    }
    Ops.public(finding) |> Map.merge(%{"url" => duplicate.url, "merged_url" => original.url, "decision_cta" => cta})
  end

  def request_decision(id, actor, %{"task" => task_id} = data) when map_size(data) == 1 do
    if Agentboard.Input.slug?(task_id) do
      with {:ok, request} <- Ops.transaction(fn ->
      finding = Ops.fetch!(DuplicateFinding, id, "Duplicate finding not found")
      %{rows: [[linked?]]} = Repo.statement!("SELECT EXISTS(SELECT 1 FROM delivery_task_links WHERE pull_request_id=$1 AND task_id=$2)", [id, task_id])
      unless linked?, do: Ops.reject("conflict", "Decision must belong to the duplicate PR's own linked card")
      duplicate = Ash.get!(PullRequest, id)
      original = Ash.get!(PullRequest, finding.merged_pull_request_id)
      %{"task" => task_id, "kind" => "blocked_decision",
        "gate" => "duplicate-pr:#{duplicate.owner}/#{duplicate.repo}:#{duplicate.number}:merged:#{original.number}",
        "question" => "Close possible duplicate #{duplicate.url}, or keep it as a deliberate follow-up to merged #{original.url}?",
        "findings" => "Retained possible duplicate: #{duplicate.url}; merged original: #{original.url}; basis: #{finding.basis}; finding: #{finding.id}; snapshot: #{finding.snapshot_id}; merged snapshot: #{finding.merged_snapshot_id}.",
        "options" => ["Close duplicate", "Keep deliberate follow-up"]}
    end) do
      # #100 verifies caller identity/live ownership under its own task lock.
      # The collector never calls this function or manufactures an owner actor.
      Agentboard.Decisions.request(actor, request)
    end
    else
      {:error, "invalid_input", "Only a linked task field is accepted"}
    end
  end
  def request_decision(_, _, _), do: {:error, "invalid_input", "Only a linked task field is accepted"}
end
