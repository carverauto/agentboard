import Config

config :agentboard,
  ecto_repos: [Agentboard.Repo],
  ash_domains: [
    Agentboard.Board,
    Agentboard.Evidence,
    Agentboard.Delivery,
    Agentboard.Housekeeping,
    Agentboard.Context
  ]

config :ash,
  include_embedded_source_by_default?: false,
  default_string_length_count: :codepoints

config :agentboard, :rate_limits,
  ip: 120,
  agent: 60,
  window_ms: 60_000,
  max_buckets: 20_000,
  watch_ip: 20,
  watch_agent: 5,
  max_watches: 1_000

config :agentboard, AgentboardWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: AgentboardWeb.ErrorJSON], layout: false],
  pubsub_server: Agentboard.PubSub,
  live_view: [signing_salt: "agentboard-live"],
  server: false

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "token", "secret"]
config :logger, :console, format: "$time $metadata[$level] $message\n", metadata: [:request_id]

import_config "#{config_env()}.exs"

