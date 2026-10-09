defmodule Agentboard.Wake.Reconcile do
  @moduledoc "Bounded pending-source discovery, never transport or native work."
  use Oban.Worker,
    queue: :housekeeping,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Agentboard.Cooperation.Subscription
  require Ash.Query

  def enqueue(id), do: %{"id" => id} |> new() |> Oban.insert!()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Ash.get!(Subscription, id, not_found_error?: false) do
      nil ->
        :ok

      %{revoked: true} ->
        :ok

      subscription ->
        case Agentboard.WakeIntents.reconcile(id, subscription.repos, 32) do
          {:ok, _} -> {:snooze, 30}
          {:error, code, _} -> {:error, code}
        end
    end
  end

  # The existing minute scheduler repairs missing discovery jobs in bounded
  # pages. Each live worker's one job polls every 30 seconds and rereads scopes.
  def ensure_jobs do
    Subscription
    |> Ash.Query.filter(
      revoked == false and
        fragment(
          "NOT EXISTS (SELECT 1 FROM oban_jobs j WHERE j.worker='Agentboard.Wake.Reconcile' AND j.args->>'id'=? AND j.state IN ('available','scheduled','executing','retryable'))",
          id
        )
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(20)
    |> Ash.read!()
    |> Enum.each(&enqueue(&1.id))
  end
end
