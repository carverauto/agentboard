defmodule Agentboard.Delivery.Rebase do
  @moduledoc "Definitive dirty evidence creates one gated repair, inbox notice and normal harness-delivery intent atomically."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Agent, Task}
  alias Agentboard.Delivery.{RebaseFollowUp, PullRequest, TaskLink}
  alias Agentboard.{Availability, Repo, Cooperation.Runtime}
  require Ash.Query
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}

  # Caller holds PollState's reservation lock. No source-task locks or provider I/O.
  def observe(snapshot, result, stamp) do
    cond do
      result.lifecycle != "open" ->
        :ok

      result.payload["mergeable"] == true and result.payload["mergeable_state"] != "dirty" ->
        resolve(snapshot, stamp)

      result.payload["mergeable"] == false and result.payload["mergeable_state"] == "dirty" and
          enabled?() ->
        prior =
          RebaseFollowUp
          |> Ash.Query.filter(
            pull_request_id == ^snapshot.pull_request_id and head_sha == ^result.head_sha
          )
          |> Ash.read_one!()

        if is_nil(prior), do: publish(snapshot, result, stamp)

      true ->
        :ok
    end
  end

  defp publish(snapshot, result, stamp) do
    # Recheck at the write boundary; collection itself is independent of cooperation.
    if enabled?() do
      pr = Ash.get!(PullRequest, snapshot.pull_request_id)

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

      follow_id = Ash.UUID.generate()
      Availability.lock_admission()

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
        if owner do
          try do
            grant = Availability.admit(task, "assign", @actor, %{"to" => owner})

            assigned =
              Ops.update(
                task,
                :assign,
                Map.merge(
                  %{
                    status: "assigned",
                    assignee_id: owner,
                    assigner_id: @actor["agent"],
                    revision: 2,
                    updated_at: stamp
                  },
                  grant
                ),
                @actor
              )

            {assigned, owner}
          rescue
            _ in Agentboard.Board.OperationError -> {task, nil}
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
            responsible_id: responsible,
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

      Ops.notify_task_owner(
        task,
        @actor,
        "Merge conflict: #{pr.url} at head #{result.head_sha}, base #{result.base_sha}. Follow up on #{task.id}; rebase and verify CI before moving on.",
        stamp
      )

      capture(f, pr)
    end
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
        Repo.statement!(
          "SELECT id FROM delivery_rebase_follow_ups WHERE id::text=$1 FOR UPDATE",
          [f.id]
        )

        f = Ash.get!(RebaseFollowUp, f.id)
        pr = Ash.get!(PullRequest, f.pull_request_id)

        if is_nil(f.resolved_at) and
             String.downcase(pr.owner <> "/" <> pr.repo) in subscription.repos do
          e = capture(f, pr)

          Runtime.ensure_delivery(e, subscription.id, @actor)
        end
      end)
    end
  end

  defp capture(f, pr),
    do:
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

  defp enabled?, do: Application.get_env(:agentboard, :cooperation_enabled, false)
end
