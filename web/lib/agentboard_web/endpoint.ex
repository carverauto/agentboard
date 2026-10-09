defmodule AgentboardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agentboard

  @session_options [
    store: :cookie,
    key: "_agentboard",
    signing_salt: "board-session",
    same_site: "Lax",
    http_only: true
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :session_options, []}]],
    longpoll: false
  )

  # The socket and HTTP plug must use the same runtime cookie configuration.
  # Cloudflare mode is HTTPS-only even when TLS terminates at the tunnel edge.
  def session_options do
    if Agentboard.FrontendAuth.enabled?(),
      do: @session_options ++ [secure: true, encryption_salt: "board-session-encryption"],
      else: @session_options
  end

  plug(Plug.Static, at: "/", from: :agentboard, gzip: false, only: ~w(assets favicon.ico))
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(:runtime_session)
  plug(AgentboardWeb.Router)

  defp runtime_session(conn, _options),
    do: Plug.Session.call(conn, Plug.Session.init(session_options()))
end
