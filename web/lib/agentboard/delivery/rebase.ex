defmodule Agentboard.Delivery.Rebase do
  @moduledoc "Definitive dirty evidence creates one gated repair, inbox notice and normal harness-delivery intent atomically. The collector calls this inside its fenced snapshot/projection transaction."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Agent, Task}
  alias Agentboard.Delivery.{RebaseFollowUp, PullRequest, TaskLink}
  alias Agentboard.{Availability, Repo, Cooperation.Runtime}
  require Ash.Query
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}

  # Caller holds PollState's reservation lock. No source-task locks or provider I/O.
  def observe(snapshot, result, stamp) do
    case Agentboard.Delivery.ConflictPolicy.mode() do
      "apply" -> Agentboard.Delivery.ConflictOrders.observe(snapshot, result, stamp)
      "dry_run" -> Agentboard.Delivery.ConflictDryRun.observe(snapshot, result, stamp)
      "disabled" -> observe_legacy(snapshot, result, stamp)
    end
  end

  defp observe_legacy(snapshot, result, stamp) do
    case Agentboard.Delivery.ConflictPolicy.observation_state(result) do
      :closed ->
        :ok

      :clean ->
        resolve(snapshot, stamp)

      :dirty ->
        if enabled?() do
          prior =
            RebaseFollowUp
            |> Ash.Query.filter(
              pull_request_id == ^snapshot.pull_request_id and head_sha == ^result.head_sha
            )
            |> Ash.read_one!()

          if is_nil(prior), do: publish(snapshot, result, stamp)
        end

      :unknown ->
        :ok
    end
  end

  defp publish(snapshot, result, stamp) do
    # Recheck at the write boundary; collection itself is independent of cooperation.
    if enabled?() do
      {f, pr, task} = create_follow_up(snapshot, result, stamp)

      event = capture_event(f, pr)

      Ops.notify_task_owner(
        task,
        @actor,
        "Merge conflict: #{pr.url} at head #{result.head_sha}, base #{result.base_sha}. Follow up on #{task.id}; rebase and verify CI before moving on.\n" <>
          Runtime.fallback_marker(event.source_key),
        stamp
      )

      assignee =
        case Ash.get!(Task, f.repair_task_id, not_found_error?: false) do
          nil -> nil
          current -> current.assignee_id
        end

      # The notify above carries the exact source marker, so the fallback
      # adopts it instead of a second DM. Markerless notes are never adopted.
      Runtime.fallback(event, [assignee], @actor, recipient: f.responsible_id || "captain")

      event
    end
  end

  # The canonical conflict producer also uses this repair-only creation path.
  # Caller holds its base/poll fence; source task claims remain untouched.
  def create_follow_up(snapshot, result, stamp, options \\ []) do
    pr = Ash.get!(PullRequest, snapshot.pull_request_id)

    %{links: links, owner: owner} = source_attribution(pr)

    follow_id = Ash.UUID.generate()
    Availability.lock_admission()
    Agentboard.QueueAdmission.lock(owner)
    routing? = Keyword.get(options, :routing, false)

    recipient = recipient(owner, follow_id, pr, routing?)

    task =
      Ops.create(
        Task,
        :create,
        %{
          id: "rebase-repair-" <> follow_id,
          title: "Rebase: #{pr.owner}/#{pr.repo} ##{pr.number}",
          description:
            "GitHub confirmed merge conflict at head #{result.head_sha}, base #{result.base_sha}. Sources: #{Enum.map_join(links, ", ", & &1.task_id)}. #{pr.url}. Rebase, verify CI, and explicitly complete this repair; receiving a notice does not finish it.",
          priority: 1,
          repo: pr.owner <> "/" <> pr.repo,
          labels: ["rebase-repair"],
          pr_url: pr.url,
          status: "open",
          revision: 1,
          created_at: stamp,
          updated_at: stamp
        },
        @actor
      )

    {task, responsible} =
      if recipient do
        grant =
          try do
            Availability.admit(task, "assign", @actor, %{"to" => recipient})
          rescue
            e in Agentboard.Board.OperationError ->
              if e.code == "conflict", do: nil, else: reraise(e, __STACKTRACE__)
          end

        if grant do
          assigned =
            Ops.update(
              task,
              :assign,
              Map.merge(
                %{
                  status: "assigned",
                  assignee_id: recipient,
                  assigner_id: @actor["agent"],
                  revision: 2,
                  updated_at: stamp
                },
                grant
              ),
              @actor
            )

          {assigned, recipient}
        else
          {task, nil}
        end
      else
        {task, nil}
      end

    f =
      Ops.create(
        RebaseFollowUp,
        :record,
        %{
          id: follow_id,
          pull_request_id: pr.id,
          head_sha: result.head_sha,
          base_sha: result.base_sha,
          snapshot_id: snapshot.id,
          repair_task_id: task.id,
          responsible_id: if(routing?, do: owner, else: responsible),
          created_at: stamp
        },
        @actor
      )

    Ops.project_event(
      task.id,
      @actor,
      "pr_conflict",
      nil,
      nil,
      task.revision,
      %{
        pull_request_id: pr.id,
        head_sha: result.head_sha,
        base_sha: result.base_sha,
        snapshot_id: snapshot.id,
        source_tasks: Enum.map(links, & &1.task_id)
      },
      stamp
    )

    {f, pr, task}
  end

  # Submission attribution is immutable and excludes system repair cards.
  # Both apply and audit-only evaluation consume this exact source relation.
  def source_attribution(pr) do
    links =
      TaskLink
      |> Ash.Query.filter(
        pull_request_id == ^pr.id and
          fragment(
            "NOT EXISTS (SELECT 1 FROM delivery_obligations WHERE repair_task_id=?) AND NOT EXISTS (SELECT 1 FROM delivery_rebase_follow_ups WHERE repair_task_id=?)",
            task_id,
            task_id
          )
      )
      |> Ash.read!()

    owners = links |> Enum.map(& &1.submitted_by_id) |> Enum.uniq()

    owner =
      if length(owners) == 1 and not is_nil(hd(owners)) and
           Ash.get!(Agent, hd(owners), not_found_error?: false),
         do: hd(owners)

    %{links: links, owner: owner}
  end

  def guard_pr_identity!(id, data) do
    if Map.has_key?(data, "pr_url") do
      %{rows: [[repair?]]} =
        Repo.statement!(
          "SELECT EXISTS(SELECT 1 FROM delivery_rebase_follow_ups WHERE repair_task_id=$1)",
          [id]
        )

      if repair?, do: Ops.reject("conflict", "A rebase repair retains its original PR identity")
    end
  end

  defp recipient(owner, _follow_id, _pr, false), do: owner
  defp recipient(nil, _follow_id, _pr, true), do: nil

  defp recipient(owner, follow_id, pr, true) do
    evidence =
      Agentboard.Eligibility.admit(owner, %{
        id: "rebase-repair-" <> follow_id,
        repo: pr.owner <> "/" <> pr.repo,
        labels: ["rebase-repair"]
      })

    if evidence.eligible, do: owner
  end

  defp resolve(snapshot, stamp) do
    RebaseFollowUp
    |> Ash.Query.filter(pull_request_id == ^snapshot.pull_request_id and is_nil(resolved_at))
    |> Ash.read!()
    |> Enum.each(fn f ->
      Ops.update(f, :resolve, %{resolved_at: stamp, resolution_snapshot_id: snapshot.id}, @actor)

      %{rows: rows} =
        Repo.statement!(
          "SELECT d.id FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.task_id=$1 AND e.kind='pr_conflict' AND d.state IN ('pending','received') ORDER BY d.id FOR UPDATE OF d",
          [f.repair_task_id]
        )

      Enum.each(rows, fn [id] ->
        Ops.update(
          Ash.get!(Agentboard.Cooperation.Delivery, id),
          :change,
          %{state: "suppressed"},
          @actor
        )
      end)
    end)
  end

  # Late enrollment must recover an unresolved signal even when its original
  # immutable audience was empty. A durable Delivery owns the exact receipt.
  def bootstrap(subscription) do
    if enabled?() do
      RebaseFollowUp
      |> Ash.Query.filter(responsible_id == ^subscription.id and is_nil(resolved_at))
      |> Ash.read!()
      |> Enum.each(fn f ->
        if f.current_order_id do
          Agentboard.Delivery.ConflictOrders.bootstrap(f, subscription)
        else
          Repo.statement!(
            "SELECT id FROM delivery_rebase_follow_ups WHERE id::text=$1 FOR UPDATE",
            [f.id]
          )

          f = Ash.get!(RebaseFollowUp, f.id)
          pr = Ash.get!(PullRequest, f.pull_request_id)

          if is_nil(f.resolved_at) and
               String.downcase(pr.owner <> "/" <> pr.repo) in subscription.repos do
            e = capture_event(f, pr)

            Runtime.ensure_delivery(e, subscription.id, @actor)
          end
        end
      end)
    end
  end

  defp capture_event(f, pr) do
    Runtime.capture(
      %{
        source_key: "rebase:#{f.id}",
        kind: "pr_conflict",
        repo: pr.owner <> "/" <> pr.repo,
        task_id: f.repair_task_id,
        summary:
          "#{pr.url} conflicts at head #{f.head_sha}, base #{f.base_sha}; rebase repair #{f.repair_task_id}.",
        source_url: pr.url,
        priority: 1
      },
      recipient: f.responsible_id || "captain"
    )
  end

  defp enabled?, do: Application.get_env(:agentboard, :cooperation_enabled, false)
end
