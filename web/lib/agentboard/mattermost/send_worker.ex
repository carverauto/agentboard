defmodule Agentboard.Mattermost.SendWorker do
  @moduledoc "One intent per job; the Ash action owns fencing and uncertainty."
  use Oban.Worker,
    queue: :mattermost_sender,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    Agentboard.Mattermost.Router
    |> Ash.ActionInput.for_action(:send_intent, %{id: id},
      actor: %{role: :system, id: "mattermost-bridge"}
    )
    |> Ash.run_action()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, error} -> AshOban.check_for_oban_return(error) || {:error, error}
    end
  end
end
