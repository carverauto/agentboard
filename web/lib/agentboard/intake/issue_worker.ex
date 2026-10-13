defmodule Agentboard.Intake.IssueWorker do
  @moduledoc "One intake item per job; the outbox claim owns fencing, backoff and uncertainty."
  use Oban.Worker,
    queue: :intake,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    Agentboard.Intake.Dispatcher
    |> Ash.ActionInput.for_action(:create_issue, %{id: id},
      actor: %{role: :system, id: "system-intake"}
    )
    |> Ash.run_action()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, error} -> AshOban.check_for_oban_return(error) || {:error, error}
    end
  end
end
