defmodule Agentboard.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Repo owns a connection pool; contexts run in each request/LiveView process.
    # PubSub owns subscriptions, and Endpoint owns network connections.
    children = [
      Agentboard.Repo,
      {Phoenix.PubSub, name: Agentboard.PubSub},
      Agentboard.RateLimits.Owner,
      Agentboard.Notifications,
      AgentboardWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Agentboard.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AgentboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

