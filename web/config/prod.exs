import Config
config :logger, level: :info

config :agentboard, AgentboardWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

