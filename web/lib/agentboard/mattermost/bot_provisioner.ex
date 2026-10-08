defmodule Agentboard.Mattermost.BotProvisioner do
  @moduledoc "Phase 2 elastic bot lifecycle jobs: provision on register, finish retirements. Unique per action plus agent so bursts collapse."
  use Oban.Worker,
    queue: :mattermost_provision,
    max_attempts: 8,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "provision", "agent_id" => agent_id}}) do
    case Agentboard.Mattermost.ElasticBots.provision(agent_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "retire", "agent_id" => agent_id}}) do
    case Agentboard.Mattermost.ElasticBots.retire_job(agent_id) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  def perform(%Oban.Job{}) do
    {:error, :unknown_action}
  end
end
