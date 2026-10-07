defmodule Agentboard.Mattermost.VerifyWorker do
  @moduledoc "One identity verification per job; failures stay visible, never silent."
  use Oban.Worker,
    queue: :mattermost_verify,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"agent_id" => agent_id}}) do
    case Agentboard.Mattermost.Conversations.verify(agent_id) do
      {:ok, result} -> {:ok, result}
      {:error, message} -> {:error, message}
    end
  end
end
