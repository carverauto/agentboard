defmodule Agentboard.Delivery.PollWorker do
  @moduledoc "One PR per job; the Ash action owns reservation and provider admission."
  use Oban.Worker,
    queue: :delivery_polling,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}),
    do: Agentboard.Delivery.WorkerAction.run(Agentboard.Delivery.Observation, :poll, %{id: id})
end
