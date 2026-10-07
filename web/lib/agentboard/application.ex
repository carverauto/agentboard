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
      {Oban,
       AshOban.config(worker_domains(),
         repo: Agentboard.Repo,
         queues: [
           housekeeping: 1,
           delivery_discovery: [limit: 1, paused: not discovery_enabled?()]
         ],
         plugins: [Oban.Plugins.Cron, Oban.Plugins.Pruner]
       )},
      AgentboardWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Agentboard.Supervisor)
  end

  defp discovery_enabled?, do: Application.get_env(:agentboard, :pr_discovery_enabled, false)

  defp worker_domains do
    if discovery_enabled?(),
      do: [Agentboard.Housekeeping, Agentboard.Delivery],
      else: [Agentboard.Housekeeping]
  end

  @impl true
  def config_change(changed, _new, removed) do
    AgentboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

