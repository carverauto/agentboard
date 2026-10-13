defmodule Agentboard.FleetRefill.Wake do
  @moduledoc "Event-triggered refill pass; at most one queued or running job; the minute schedule covers events it coalesces."
  use Oban.Worker,
    queue: :fleet_refill,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  def enqueue, do: %{} |> new() |> Oban.insert!()

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _} = Agentboard.FleetRefill.run_all()
    :ok
  end
end
