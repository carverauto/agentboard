defmodule Agentboard.Delivery.MergeDisposition do
  @moduledoc "Audited Review completion from retained merge evidence, independently of CI qualification."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias Agentboard.Board.Operations
  alias Agentboard.Board.Resources.Task
  alias Agentboard.Delivery.{CISnapshot, Inventory, PollState, Scheduling, TaskLink}
  alias Agentboard.Repo
  require Ash.Query

  oban do
    scheduled_actions do
      schedule :reconcile_merges, "* * * * *" do
        action(:reconcile)
        queue(:delivery_scheduler)
        max_attempts(5)
        worker_module_name(Agentboard.Delivery.ReconcileMergedReviews)
        default_actor(%{role: :system, id: "delivery-merge-disposition"})
      end
    end
  end

  policies do
    policy action(:reconcile) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    action :reconcile, :map do
      argument(:after_id, :string, constraints: [trim?: false, allow_empty?: true])
      run(fn input, _context -> reconcile(input.arguments[:after_id]) end)
    end
  end

  defp reconcile(cursor) do
    if Scheduling.enabled?() do
      query =
        Task
        |> Ash.Query.filter(status == "review" and not is_nil(pr_url))
        |> Ash.Query.filter(
          fragment(
            "NOT EXISTS (SELECT 1 FROM delivery_obligations WHERE repair_task_id = ?)",
            id
          )
        )
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(101)

      query = if cursor, do: Ash.Query.filter(query, id > ^cursor), else: query

      with {:ok, tasks} <- query |> Repo.read_query() |> Ash.read(),
           {:ok, counts} <- complete_page(Enum.take(tasks, 100)) do
        next = if length(tasks) > 100, do: Enum.at(tasks, 99).id

        # Cursor continuation is an Oban job, never volatile process state.
        # Replaying a partially completed page sees done tasks and does nothing.
        if next do
          AshOban.schedule(__MODULE__, :reconcile_merges, action_arguments: %{after_id: next})
        end

        {:ok, Map.put(counts, :next_cursor, next)}
      else
        {:error, _code, message} -> {:error, message}
        {:error, error} -> {:error, error}
      end
    else
      {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
    end
  end

  defp complete_page(tasks) do
    Enum.reduce_while(tasks, {:ok, %{scanned: 0, completed: 0}}, fn task, {:ok, counts} ->
      case Operations.transaction(fn -> complete_task(task.id) end) do
        {:ok, completed?} ->
          counts = %{
            scanned: counts.scanned + 1,
            completed: counts.completed + if(completed?, do: 1, else: 0)
          }

          {:cont, {:ok, counts}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp complete_task(id) do
    # Inventory/pruning acquires the task before its PR state. Do not add a
    # PollState -> source task edge to the collector's fenced commit transaction.
    Operations.lock_task(id)
    task = Ash.get!(Task, id)

    with true <- Scheduling.enabled?() and task.status == "review",
         false <- repair_task?(id),
         {:ok, pr} <- Inventory.canonical(task.pr_url) do
      # Submission history is immutable: a later link cannot hide another
      # unfinished PR. Bound one aggregate and acquire shared PR locks in order.
      links =
        TaskLink
        |> Ash.Query.filter(task_id == ^id)
        |> Ash.Query.sort(pull_request_id: :asc)
        |> Ash.Query.limit(101)
        |> Ash.read!()

      if length(links) <= 100 do
        ids = [pr.id | Enum.map(links, & &1.pull_request_id)] |> Enum.uniq() |> Enum.sort()

        Repo.statement!(
          "SELECT id FROM delivery_poll_states WHERE id=ANY($1::text[]) ORDER BY id FOR UPDATE",
          [ids]
        )

        states = PollState |> Ash.Query.filter(id in ^ids) |> Ash.read!()

        evidence =
          Enum.map(states, fn state ->
            snapshot = state.snapshot_id && Ash.get!(CISnapshot, state.snapshot_id)
            {state, snapshot}
          end)

        if length(states) == length(ids) and
             Enum.all?(evidence, fn {state, snapshot} -> merged_evidence?(state, snapshot) end) and
             Scheduling.enabled?() do
          snapshots = Enum.map(evidence, fn {_state, snapshot} -> snapshot end)
          current = Enum.find(snapshots, &(&1.pull_request_id == pr.id))
          Operations.complete_merged_pr(task, current, pr.url, snapshots, Operations.now())
          true
        else
          false
        end
      else
        false
      end
    else
      _ -> false
    end
  end

  defp repair_task?(id) do
    %{rows: [[exists?]]} =
      Repo.statement!("SELECT EXISTS (SELECT 1 FROM delivery_obligations WHERE repair_task_id=$1)", [id])

    exists?
  end

  # Merge is irreversible lifecycle evidence; it remains usable after downtime
  # or a later failed provider fetch. It never certifies passing or fresh CI.
  defp merged_evidence?(%PollState{lifecycle: "merged"} = state, %CISnapshot{lifecycle: "merged"} = snapshot) do
    snapshot.pull_request_id == state.id and snapshot.generation <= state.generation and
      snapshot.head_sha == state.head_sha and snapshot.base_sha == state.base_sha and
      snapshot.observed_at == state.observed_at
  end

  defp merged_evidence?(_state, _snapshot), do: false
end
