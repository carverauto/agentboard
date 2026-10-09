defmodule Agentboard.WakeIntents do
  @moduledoc """
  Canonical wake occurrences. These records reference existing cooperation
  deliveries; they never acknowledge sources, claim work or grant native custody.
  Capture runs inside the source owner's transaction, taking only the occurrence
  lock after canonical locks. Transport reservation must lock canonical sources
  before entering the worker dispatcher.
  """
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Message, Task}
  alias Agentboard.Wake.Intent
  alias Agentboard.Repo
  require Ash.Query

  @system %{
    "agent" => "wake-intents",
    "model" => "system",
    "harness" => "ash",
    :wake_internal => true
  }
  @reasons ~w(unread_dm decision_answered claim_expiring idle_assigned blocker_shipped)
  @sources ~w(board_message mattermost_post decision_wake task_claim task_assignment blocker_event)

  # Caller supplies canonical records, never source text or client attribution.
  # Messages derive scope only from their canonical task, never enrollment.
  # Legacy taskless messages remain readable but cannot create a scoped wake.
  def capture_message(message, actor, repo \\ nil)

  # Typed producers call this inside their sole canonical message transaction,
  # with generic notice capture suppressed. Identity remains Message.id/version.
  def capture_message(message, actor, %{"repo" => repo, "order_ref" => ref} = options) do
    unless Enum.sort(Map.keys(options)) == ~w(order_ref repo) and order_ref?(ref) and
             message.recipient_id == ref["recipient_id"] and
             message.task_id == ref["repair_task_id"],
           do: Ops.reject("invalid_input", "Exact typed conflict order reference required")

    capture_message_source(message, actor, repo, %{"order_ref" => ref})
  end

  def capture_message(message, actor, repo), do: capture_message_source(message, actor, repo, %{})

  defp capture_message_source(message, actor, _repo, source_ref) do
    task = if message.task_id, do: Ash.get!(Task, message.task_id, not_found_error?: false)
    repo = if task, do: task.repo

    if message.recipient_id && message.sender_id != message.recipient_id &&
         is_nil(message.read_at) && canonical_repo(repo) do
      capture(
        %{
          recipient_id: message.recipient_id,
          repo: canonical_repo(repo),
          reason: "unread_dm",
          source_kind: "board_message",
          source_id: to_string(message.id),
          source_version: DateTime.to_iso8601(message.created_at),
          task_id: message.task_id,
          source_ref: source_ref,
          cooperation_event_id: nil
        },
        actor
      )
    end
  end

  defp order_ref?(ref) when is_map(ref) do
    Enum.sort(Map.keys(ref)) ==
      Enum.sort(
        ~w(kind order_id order_revision repair_task_id pull_request_id default_ref default_tip_sha evaluation_base_ref evaluation_base_sha recipient_id)
      ) and
      ref["kind"] == "pr_conflict_order" and match?({:ok, _}, Ecto.UUID.cast(ref["order_id"])) and
      is_integer(ref["order_revision"]) and ref["order_revision"] > 0 and
      Agentboard.Input.slug?(ref["repair_task_id"]) and
      Agentboard.Input.slug?(ref["recipient_id"]) and
      Enum.all?(
        ~w(default_ref evaluation_base_ref),
        &(is_binary(ref[&1]) and String.valid?(ref[&1]) and String.length(ref[&1]) in 1..255)
      ) and
      Enum.all?(
        ~w(default_tip_sha evaluation_base_sha),
        &(is_binary(ref[&1]) and Regex.match?(~r/^[0-9a-f]{40}$/, ref[&1]))
      ) and
      is_binary(ref["pull_request_id"]) and
      Regex.match?(~r/^[0-9a-f]{64}$/, ref["pull_request_id"])
  end

  defp order_ref?(_), do: false

  def capture_decision(wake, request, task, actor) do
    if request.status == "answered" and wake.status == "pending" and
         not is_nil(canonical_repo(task.repo)) do
      capture(
        %{
          recipient_id: request.requester_id,
          repo: canonical_repo(task.repo),
          reason: "decision_answered",
          source_kind: "decision_wake",
          source_id: wake.id,
          source_version: DateTime.to_iso8601(wake.answered_at),
          task_id: task.id,
          source_ref: %{"request_id" => request.id, "source_key" => wake.source_key},
          cooperation_event_id: wake.worker_event_id
        },
        actor
      )
    end
  end

  def capture_task(task, actor) do
    stamp = Ops.now()

    if task.assignee_id && canonical_repo(task.repo) do
      cond do
        ((task.status in ~w(in_progress blocked review) and task.claim_expires_at) &&
           DateTime.compare(task.claim_expires_at, stamp) == :gt) and
            DateTime.diff(task.claim_expires_at, stamp) <= 900 ->
          capture_task_reason(
            task,
            "claim_expiring",
            "task_claim",
            DateTime.to_iso8601(task.claim_expires_at),
            %{},
            actor
          )

        task.status == "assigned" and task.assignment_authorized ->
          agent =
            Ash.get!(Agentboard.Board.Resources.Agent, task.assignee_id, not_found_error?: false)

          %{rows: rows} =
            Repo.statement!(
              "SELECT new_revision FROM task_events WHERE task_id=$1 AND kind IN ('assign','handoff') ORDER BY id DESC LIMIT 1",
              [task.id]
            )

          if agent && agent.reported_status == "idle" do
            case rows do
              [[revision]] ->
                capture_task_reason(
                  task,
                  "idle_assigned",
                  "task_assignment",
                  to_string(revision),
                  %{"assignment_revision" => revision},
                  actor
                )

              [] ->
                nil
            end
          end

        true ->
          nil
      end
    end
  end

  defp capture_task_reason(task, reason, kind, version, ref, actor) do
    capture(
      %{
        recipient_id: task.assignee_id,
        repo: canonical_repo(task.repo),
        reason: reason,
        source_kind: kind,
        source_id: task.id,
        source_version: version,
        task_id: task.id,
        source_ref: ref,
        cooperation_event_id: nil
      },
      actor
    )
  end

  def reason_hash(recipient, repo, reason, kind, id, version) do
    ["agentboard-wake-v1", recipient, canonical_repo(repo), reason, kind, id, version]
    |> Jason.encode!()
    |> digest()
  end

  defp capture(attrs, actor) do
    unless (attrs.reason in @reasons and attrs.source_kind in @sources and attrs.repo) &&
             Enum.all?(
               [attrs.recipient_id, attrs.source_id, attrs.source_version],
               &(is_binary(&1) and byte_size(&1) in 1..240)
             ),
           do: Ops.reject("invalid_input", "Canonical bounded wake identity required")

    hash =
      reason_hash(
        attrs.recipient_id,
        attrs.repo,
        attrs.reason,
        attrs.source_kind,
        attrs.source_id,
        attrs.source_version
      )

    <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "agentboard-wake:" <> hash)
    Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])
    prior = Intent |> Ash.Query.filter(reason_hash == ^hash) |> Ash.read_one!()

    if prior do
      if attrs.source_ref != %{} and prior.source_ref != attrs.source_ref,
        do:
          Ops.reject(
            "conflict",
            "Canonical occurrence was captured with different typed metadata"
          )

      prior
    else
      stamp = Ops.now()

      Ops.create(
        Intent,
        :record,
        Map.merge(attrs, %{
          id: Ash.UUID.generate(),
          reason_hash: hash,
          delivery_id: nil,
          state: "pending",
          reason_code: nil,
          revision: 1,
          created_at: stamp,
          updated_at: stamp
        }),
        Map.put(actor, :wake_internal, true)
      )
    end
  end

  # Pending-state discovery: no max-ID watermark can hide a lower-ID late commit.
  # Source writes acquire canonical locks before this occurrence lock.
  def reconcile(worker_id, repos, limit \\ 32) when limit in 1..100 do
    Ops.transaction(fn ->
      Agentboard.Availability.lock_admission()

      messages =
        Message
        |> Ash.Query.filter(
          recipient_id == ^worker_id and sender_id != ^worker_id and is_nil(read_at)
        )
        |> Ash.Query.filter(
          fragment(
            "NOT EXISTS (SELECT 1 FROM decision_requests r WHERE r.message_id=?)",
            id
          )
        )
        |> Ash.Query.filter(
          fragment(
            "NOT EXISTS (SELECT 1 FROM wake_intents w WHERE w.recipient_id=? AND w.source_kind='board_message' AND w.source_id=?::text)",
            recipient_id,
            id
          )
        )
        |> Ash.Query.filter(
          fragment(
            "EXISTS (SELECT 1 FROM tasks t WHERE t.id=? AND lower(CASE WHEN position('/' IN t.repo)>0 THEN t.repo ELSE 'carverauto/' || t.repo END)=ANY(?::text[]))",
            task_id,
            ^repos
          )
        )
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      wakes =
        Agentboard.Decisions.Wake
        |> Ash.Query.filter(requester_id == ^worker_id and status == "pending")
        |> Ash.Query.filter(
          fragment(
            "NOT EXISTS (SELECT 1 FROM wake_intents w WHERE w.recipient_id=? AND w.source_kind='decision_wake' AND w.source_id=?::text)",
            requester_id,
            id
          )
        )
        |> Ash.Query.filter(
          fragment(
            "EXISTS (SELECT 1 FROM tasks t WHERE t.id=? AND lower(CASE WHEN position('/' IN t.repo)>0 THEN t.repo ELSE 'carverauto/' || t.repo END)=ANY(?::text[]))",
            task_id,
            ^repos
          )
        )
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      tasks =
        Task
        |> Ash.Query.filter(
          assignee_id == ^worker_id and status in ["assigned", "in_progress", "blocked", "review"]
        )
        |> Ash.Query.filter(
          fragment(
            "((? IN ('in_progress','blocked','review') AND ? > clock_timestamp() AND ? <= clock_timestamp()+interval '15 minutes') OR (?='assigned' AND ? AND EXISTS(SELECT 1 FROM agents a WHERE a.id=? AND a.reported_status='idle')))",
            status,
            claim_expires_at,
            claim_expires_at,
            status,
            assignment_authorized,
            assignee_id
          )
        )
        |> Ash.Query.filter(
          fragment(
            "NOT EXISTS(SELECT 1 FROM wake_intents w WHERE w.recipient_id=? AND w.source_id=? AND ((CASE WHEN w.source_kind='task_claim' THEN w.source_version::timestamptz END)=? OR (w.source_kind='task_assignment' AND w.source_version=(SELECT new_revision::text FROM task_events e WHERE e.task_id=? AND e.kind IN ('assign','handoff') ORDER BY e.id DESC LIMIT 1))))",
            assignee_id,
            id,
            claim_expires_at,
            id
          )
        )
        |> Ash.Query.filter(
          fragment(
            "lower(CASE WHEN position('/' IN ?) > 0 THEN ? ELSE 'carverauto/' || ? END) = ANY(?::text[])",
            repo,
            repo,
            repo,
            ^repos
          )
        )
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      # Acquire canonical groups in stable order, before any occurrence lock.
      # In particular never hold an old message lock while acquiring its task.
      (Enum.map(tasks, & &1.id) ++
         Enum.map(wakes, & &1.task_id) ++ Enum.map(messages, & &1.task_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&Ops.lock_task/1)

      wakes
      |> Enum.map(& &1.request_id)
      |> Enum.sort()
      |> Enum.each(fn id ->
        Repo.statement!("SELECT id FROM decision_requests WHERE id=$1 FOR UPDATE", [id])
      end)

      wakes
      |> Enum.sort_by(& &1.id)
      |> Enum.each(fn wake ->
        Repo.statement!("SELECT id FROM decision_wakes WHERE id=$1 FOR UPDATE", [wake.id])
      end)

      Enum.each(messages, fn message ->
        Repo.statement!("SELECT id FROM messages WHERE id=$1 FOR UPDATE", [message.id])
      end)

      Enum.each(messages, fn message ->
        capture_message(Ash.get!(Message, message.id), @system)
      end)

      Enum.each(wakes, fn wake ->
        current = Ash.get!(Agentboard.Decisions.Wake, wake.id)
        request = Ash.get!(Agentboard.Decisions.Request, wake.request_id)
        capture_decision(current, request, Ash.get!(Task, wake.task_id), @system)
      end)

      Enum.each(tasks, fn task -> capture_task(Ash.get!(Task, task.id), @system) end)

      %{messages: length(messages), decisions: length(wakes), tasks: length(tasks)}
    end)
  end

  def canonical_repo(nil), do: nil

  def canonical_repo(repo) when is_binary(repo) do
    normalized =
      if String.contains?(repo, "/"),
        do: String.downcase(repo),
        else: "carverauto/" <> String.downcase(repo)

    if Regex.match?(~r{^[a-z0-9_.-]+/[a-z0-9_.-]+$}, normalized), do: normalized
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
