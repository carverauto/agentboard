defmodule Agentboard.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Repo owns a connection pool; contexts run in each request/LiveView process.
    # PubSub owns subscriptions, and Endpoint owns network connections.
    Agentboard.MessageMode.report_activation()

    children = [
      Agentboard.Repo,
      Agentboard.Vault,
      {Phoenix.PubSub, name: Agentboard.PubSub},
      Agentboard.RateLimits.Owner,
      Agentboard.Notifications,
      {Oban,
       worker_config(
         repo: Agentboard.Repo,
         queues: [
           housekeeping: 1,
           cooperation: [
             limit: 2,
             paused: not Application.get_env(:agentboard, :cooperation_enabled, false)
           ],
           delivery_discovery: [limit: 1, paused: not discovery_enabled?()],
           delivery_scheduler: [limit: 1, paused: not observation_enabled?()],
           delivery_polling: [limit: 4, paused: not observation_enabled?()],
           mattermost_router: [limit: 1, paused: not bridge_enabled?()],
           mattermost_sender: [limit: 2, paused: not bridge_enabled?()],
           mattermost_provision: [limit: 1]
         ],
         plugins: [Oban.Plugins.Cron, Oban.Plugins.Pruner]
       )},
      AgentboardWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Agentboard.Supervisor)
  end

  defp discovery_enabled?, do: Application.get_env(:agentboard, :pr_discovery_enabled, false)

  defp observation_enabled?, do: Agentboard.Delivery.Scheduling.enabled?()

  defp bridge_enabled?, do: Agentboard.Mattermost.Bridge.enabled?()

  defp worker_config(options) do
    config =
      AshOban.config(
        [
          Agentboard.Housekeeping,
          Agentboard.Board,
          Agentboard.Delivery,
          Agentboard.Cooperation,
          Agentboard.Mattermost
        ],
        options
      )

    plugins =
      Enum.map(config[:plugins], fn
        {Oban.Plugins.Cron, opts} ->
          entries =
            Enum.reject(opts[:crontab] || [], fn
              {_, Agentboard.Delivery.ReconcileLinks, _} -> not discovery_enabled?()
              {_, Agentboard.Delivery.ScheduleDue, _} -> not observation_enabled?()
              {_, Agentboard.Delivery.ScheduleBases, _} -> not observation_enabled?()
              {_, Agentboard.Delivery.ReconcileMergedReviews, _} -> not observation_enabled?()
              {_, Agentboard.Mattermost.RoutePending, _} -> not bridge_enabled?()
              _ -> false
            end)

          {Oban.Plugins.Cron, Keyword.put(opts, :crontab, entries)}

        plugin ->
          plugin
      end)

    Keyword.put(config, :plugins, plugins)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AgentboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
