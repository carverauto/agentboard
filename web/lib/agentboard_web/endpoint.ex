defmodule AgentboardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agentboard

  @session_options [
    store: :cookie,
    key: "_agentboard",
    signing_salt: "board-session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.Static, at: "/", from: :agentboard, gzip: false, only: ~w(assets favicon.ico))
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Session, @session_options)
  plug(AgentboardWeb.Router)
end

