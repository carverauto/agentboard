import Config

# Board remains primary unless an explicitly selected transport passes its gate.
config :agentboard, :message_mode, System.get_env("AGENTBOARD_MESSAGE_MODE", "board")

config :agentboard, :captain_token, System.get_env("AGENTBOARD_CAPTAIN_TOKEN")

# Inventory catch-up only. Provider observation and CI gates are separate stages.
config :agentboard,
       :pr_discovery_enabled,
       System.get_env("AGENTBOARD_PR_DISCOVERY_ENABLED", "false") in ["true", "1"]

# Independent scheduler/poll queues; keep off until provider/delivery acceptance.
config :agentboard,
       :pr_observation_enabled,
       System.get_env("AGENTBOARD_PR_OBSERVATION_ENABLED", "false") in ["true", "1"]

# Outbound Mattermost lifecycle bridge; keep off until bot/channel enablement.
config :agentboard,
       :mattermost_bridge_enabled,
       System.get_env("AGENTBOARD_MATTERMOST_BRIDGE_ENABLED", "false") in ["true", "1"]

# Non-secret bridge destination pins. The bot token is a secret reference and
# never belongs in config: prefer a token file, fall back to the environment.
config :agentboard,
       :mattermost_base_url,
       System.get_env("AGENTBOARD_MATTERMOST_BASE_URL")

config :agentboard,
       :mattermost_board_channel_id,
       System.get_env("AGENTBOARD_MATTERMOST_BOARD_CHANNEL_ID")

config :agentboard,
       :mattermost_bot_token_file,
       System.get_env("AGENTBOARD_MATTERMOST_BOT_TOKEN_FILE")

config :agentboard,
       :mattermost_bot_token,
       System.get_env("AGENTBOARD_MATTERMOST_BOT_TOKEN")

config :agentboard,
       :mattermost_ca_file,
       System.get_env("AGENTBOARD_MATTERMOST_CA_FILE")

config :agentboard,
       :mattermost_request_timeout_ms,
       String.to_integer(System.get_env("AGENTBOARD_MATTERMOST_REQUEST_TIMEOUT_MS", "10000"))

config :agentboard,
       :mattermost_channel_allowlist,
       System.get_env("AGENTBOARD_MATTERMOST_CHANNEL_ALLOWLIST", "")

config :agentboard,
       :public_board_url,
       System.get_env("AGENTBOARD_PUBLIC_BOARD_URL")

# Only operator-configured destinations receive credentials; provider URLs never do.
config :agentboard, :github,
  api_url: System.get_env("AGENTBOARD_GITHUB_API_URL", "https://api.github.com"),
  token: System.get_env("GITHUB_TOKEN"),
  ca_file: System.get_env("AGENTBOARD_GITHUB_CA_FILE")

config :agentboard, :rate_limits,
  ip: String.to_integer(System.get_env("API_RATE_LIMIT_IP", "120")),
  agent: String.to_integer(System.get_env("API_RATE_LIMIT_AGENT", "60")),
  window_ms: 60_000,
  max_buckets: 20_000,
  watch_ip: String.to_integer(System.get_env("API_WATCH_LIMIT_IP", "20")),
  watch_agent: String.to_integer(System.get_env("API_WATCH_LIMIT_AGENT", "5")),
  max_watches: 1_000

database_url = System.get_env("DATABASE_URL")

if database_url do
  params =
    for {key, value} <- URI.decode_query(URI.parse(database_url).query || ""),
        into: %{} do
      {String.downcase(key), String.downcase(String.trim(value))}
    end

  if Map.get(params, "ssl", "") in ["false", "0", "no", "off", "disable"] or
       Map.get(params, "sslmode", "") in ["disable", "allow", "prefer"] do
    raise "DATABASE_URL must keep TLS certificate verification enabled; refusing to start"
  end
end

host =
  if database_url,
    do: URI.parse(database_url).host,
    else: System.get_env("DATABASE_HOST", "agentboard-db-rw.agentboard.svc.cluster.local")

ca_file = System.get_env("DATABASE_CA_FILE", "/etc/agentboard/db-ca/ca.crt")

database =
  if database_url do
    [url: database_url]
  else
    [
      hostname: host,
      port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
      database: System.get_env("DATABASE_NAME", "agentboard"),
      username: System.get_env("DATABASE_USER", "agentboard"),
      password: System.get_env("DATABASE_PASSWORD")
    ]
  end

config :agentboard,
       Agentboard.Repo,
       database ++
         [
           pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
           ssl: [
             verify: :verify_peer,
             cacertfile: String.to_charlist(ca_file),
             server_name_indication: String.to_charlist(host),
             customize_hostname_check: [
               match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
             ]
           ],
           show_sensitive_data_on_connection_error: false
         ]

if config_env() == :prod do
  config :agentboard, AgentboardWeb.Endpoint,
    server: System.get_env("PHX_SERVER") in ["true", "1"],
    url: [
      host: System.get_env("PHX_HOST", "localhost"),
      port: 443,
      scheme: "https"
    ],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end

config :agentboard,
       :cooperation_enabled,
       System.get_env("AGENTBOARD_COOPERATION_ENABLED") == "true"

# Preserve invalid entries so policy classification fails closed instead of applying defaults.
ci_policies =
  case Jason.decode(System.get_env("AGENTBOARD_CI_POLICIES") || "{}") do
    {:ok, policies} when is_map(policies) -> policies
    _ -> %{}
  end

config :agentboard, :ci_policies, ci_policies

# Shared-bot inbound is a separate opt-in; deploying code does not activate chat cutover.
config :agentboard, :mattermost_inbound_enabled,
  System.get_env("AGENTBOARD_MATTERMOST_INBOUND_ENABLED", "false") in ["true", "1"]
config :agentboard, :mattermost_inbound_repo,
  System.get_env("AGENTBOARD_MATTERMOST_INBOUND_REPO")
# Unset means each worker's enrollment time. An explicit non-negative epoch
# cutoff permits an operator-approved bounded historical bootstrap.
history_start = case System.get_env("AGENTBOARD_MATTERMOST_INBOUND_HISTORY_START_MS") do
  nil -> nil
  value -> case Integer.parse(value) do
    {stamp, ""} when stamp >= 0 -> stamp
    _ -> :invalid
  end
end
config :agentboard, :mattermost_inbound_history_start_ms, history_start
