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
  def perform(%Oban.Job{args: %{"id" => id}}) do
    Agentboard.Delivery.Observation
    |> Ash.ActionInput.for_action(:poll, %{id: id},
      actor: %{role: :system, id: "delivery-observation"}
    )
    |> Ash.run_action()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, error} -> AshOban.check_for_oban_return(error) || {:error, error}
    end
  end
end
