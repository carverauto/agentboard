defmodule Agentboard.Eligibility do
  @moduledoc "Shared automatic seat eligibility v1; selection is not a claim or native custody grant."
  alias Agentboard.{Availability, QueueAdmission, Repo, SeatScope}
  alias Agentboard.Board.{Operations, Reads}
  alias Agentboard.Board.Resources.Agent
  require Ash.Query

  def queue_limit do
    case Application.get_env(:agentboard, :queue_limit, 2) do
      value when is_integer(value) and value in 1..100 -> value
      _ -> 2
    end
  end

  # The caller owns a transaction and must acquire this prefix before repair
  # task/order locks. The per-seat lock also fences manual assignment and new
  # decision creation, while policy and agent locks fence scope/model/liveness.
  def admit(id, task) do
    Availability.lock_admission()
    QueueAdmission.lock(id)
    evaluate(id, task)
  end

  # Rank a bounded snapshot, then recheck each candidate after admission. A
  # contended candidate is deferred rather than waiting while holding another
  # candidate's gate. Consumers retry on canonical state changes/deadline ticks.
  def select(task, excluded \\ []) do
    Availability.lock_admission()

    agents =
      Agent
      |> Ash.Query.filter(kind == "seat" and is_nil(retired_at))
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(1001)
      |> Ash.read!()

    if length(agents) > 1000,
      do: Operations.reject("unsupported", "Automatic selection requires a bounded fleet")

    agents
    |> Enum.reject(&(&1.id in excluded))
    |> Enum.map(fn agent -> {agent.id, queue(agent.id, task.id)} end)
    |> Enum.sort_by(fn {id, load} -> {load.count, load.last_assignment, id} end)
    |> Enum.find_value(fn {id, _} ->
      if QueueAdmission.try_lock(id) do
        case evaluate(id, task) do
          %{eligible: true} = evidence -> evidence
          _ -> nil
        end
      end
    end)
  end

  defp evaluate(id, task) do
    Repo.statement!("SELECT id FROM agents WHERE id=$1 FOR SHARE", [id])
    agent = Ash.get!(Agent, id, not_found_error?: false)
    load = queue(id, task.id)
    scope = SeatScope.get(id)

    %{rows: [[waiting]]} =
      Repo.statement!(
        "SELECT EXISTS(SELECT 1 FROM decision_requests WHERE requester_id=$1 AND status IN ('open','answered'))",
        [id]
      )

    {:ok, stale_after} = Reads.roster_threshold()

    %{rows: [[live]]} =
      Repo.statement!(
        "SELECT coalesce((SELECT last_heartbeat >= clock_timestamp()-($2::float8*interval '1 second') FROM agents WHERE id=$1),false)",
        [id, stale_after]
      )

    reason =
      cond do
        is_nil(agent) -> "unregistered"
        agent.kind != "seat" -> "not_seat"
        not is_nil(agent.retired_at) -> "retired"
        not live -> "stale"
        not Availability.active?(agent) -> "unavailable"
        waiting -> "waiting_on_captain"
        not SeatScope.managed_matches?(scope, task) -> "outside_managed_scope"
        load.count >= queue_limit() -> "queue_full"
        true -> "eligible"
      end

    %{
      agent_id: id,
      eligible: reason == "eligible",
      reason: reason,
      queue_count: load.count,
      queue_limit: queue_limit(),
      last_assignment: load.last_assignment,
      scope_revision: if(scope, do: scope.revision, else: 0)
    }
  end

  defp queue(id, repair_id) do
    %{rows: [[count, last]]} =
      Repo.statement!(
        """
        SELECT
          (SELECT count(*) FROM tasks t WHERE t.assignee_id=$1 AND t.id<>$2
            AND t.status IN ('assigned','in_progress','blocked','review')
            AND NOT EXISTS(SELECT 1 FROM task_archives x WHERE x.id=t.id AND x.archived_at IS NOT NULL)),
          coalesce((SELECT extract(epoch FROM max(e.created_at))::float8 FROM task_events e
            WHERE e.kind IN ('assign','handoff','claim','reclaim','repair_routed')
              AND e.data->'after'->>'assignee_id'=$1), 0::float8)
        """,
        [id, repair_id]
      )

    %{count: count, last_assignment: last}
  end
end
