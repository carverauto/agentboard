defmodule Agentboard.Delivery.Scheduling do
  @moduledoc "Durable per-PR jobs; server time and state, never an agent's current task, determine eligibility."
  alias Agentboard.Board.Operations
  alias Agentboard.Delivery.{Github, PollWorker, Polling}
  alias Agentboard.Repo

  @actor %{"agent" => "delivery-observation", "model" => "system", "harness" => "ash"}

  def enabled?, do: Application.get_env(:agentboard, :pr_observation_enabled, false)

  # Called inside the canonical-PR submission transaction. The persisted due
  # row remains authoritative if the job notification is missed or lost.
  def linked(id) do
    if enabled?(), do: enqueue(id)
  end

  def enqueue(id), do: %{"id" => id} |> PollWorker.new() |> Oban.insert!()

  def tick do
    if enabled?() do
      with {:ok, enrolled} <- reconcile_missing(),
           {:ok, scheduled} <- schedule_due() do
        {:ok, %{enrolled: enrolled, scheduled: scheduled}}
      else
        {:error, _code, message} -> {:error, message}
      end
    else
      snooze()
    end
  end

  def poll(id) do
    if enabled?() do
      case Polling.reserve_pr(id) do
        {:ok, []} -> {:ok, %{skipped: true}}
        {:ok, [reservation]} -> admitted_poll(reservation)
        {:error, _code, message} -> {:error, message}
      end
    else
      snooze()
    end
  end

  defp admitted_poll(reservation) do
    case Github.collect(reservation) do
      {:ok, observation} ->
        case Polling.commit_observation(reservation, observation) do
          {:ok, projection} -> {:ok, %{observed: projection["ci_state"]}}
          {:error, "disabled", _} -> snooze()
          {:error, "conflict", _} -> {:ok, %{superseded: true}}
          {:error, _code, message} -> {:error, message}
        end

      {:error, "disabled", _} ->
        snooze()

      {:error, reason, seconds} ->
        defer(reservation, seconds, reason)
    end
  end

  defp defer(reservation, seconds, reason) do
    case Polling.defer_poll(
           reservation.id,
           reservation.attempt_id,
           reservation.generation,
           seconds,
           reason
         ) do
      {:ok, _state} -> {:ok, %{deferred: reason, retry_after: seconds}}
      {:error, "disabled", _} -> snooze()
      {:error, "conflict", _} -> {:ok, %{superseded: true}}
      {:error, _code, message} -> {:error, message}
    end
  end

  defp reconcile_missing do
    Operations.transaction(fn ->
      %{rows: rows} =
        Repo.statement!(
          "SELECT pr.id FROM delivery_pull_requests pr LEFT JOIN delivery_poll_states s ON s.id=pr.id WHERE s.id IS NULL OR (NOT s.enabled AND s.lifecycle='closed' AND s.next_poll_at<=clock_timestamp()) ORDER BY pr.id LIMIT 100",
          []
        )

      Enum.each(rows, fn [id] ->
        <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "agentboard-pr:" <> id)
        Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])
        Polling.enroll(id, Operations.now(), @actor)
      end)

      length(rows)
    end)
  end

  defp schedule_due do
    Operations.transaction(fn ->
      %{rows: rows} =
        Repo.statement!(
          "SELECT s.id FROM delivery_poll_states s WHERE enabled AND next_poll_at<=clock_timestamp() AND (lease_expires_at IS NULL OR lease_expires_at<=clock_timestamp()) AND NOT EXISTS (SELECT 1 FROM oban_jobs j WHERE j.worker='Agentboard.Delivery.PollWorker' AND j.args->>'id'=s.id AND j.state IN ('available','scheduled','executing','retryable')) ORDER BY next_poll_at,s.id LIMIT 100",
          []
        )

      Enum.each(rows, fn [id] -> enqueue(id) end)
      length(rows)
    end)
  end

  defp snooze, do: {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
end
