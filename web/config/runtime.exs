import Config

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
      host: System.get_env("PHX_HOST", "agentboard.farm01.carverauto.dev"),
      port: 443,
      scheme: "https"
    ],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end

