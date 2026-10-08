defmodule AgentboardWeb.Plugs.AgentAuth do
  @moduledoc "Observe ordinary board writes; worker and captain endpoints retain their verifiers."
  import Plug.Conn
  require Logger
  def init(opts), do: opts

  def call(conn, _) do
    info = Phoenix.Router.route_info(AgentboardWeb.Router, conn.method, conn.path_info, conn.host)

    if Agentboard.Auth.mode() == "observe" and conn.method not in ~w(GET HEAD OPTIONS) and
         ordinary?(info) do
      token =
        case get_req_header(conn, "authorization") do
          ["Bearer " <> value] -> value
          [] -> nil
          _ -> :invalid
        end

      actor =
        case get_req_header(conn, "x-agentboard-agent") do
          [value] -> value
          _ -> nil
        end

      route = info.route

      case Agentboard.Auth.observe(actor, token, conn.method, route) do
        {:ok, principal} ->
          assign(conn, :authenticated_agent, principal)

        {:error, _, _} ->
          :telemetry.execute([:agentboard, :auth, :write], %{count: 1}, %{
            mode: "observe",
            outcome: "observation_unavailable"
          })

          Logger.info("agentboard auth observe outcome=observation_unavailable")
          assign(conn, :authenticated_agent, nil)
      end
    else
      conn
    end
  end

  defp ordinary?(%{plug: controller}),
    do:
      controller not in [
        AgentboardWeb.WorkerController,
        AgentboardWeb.CaptainController,
        AgentboardWeb.AgentTokenController
      ]

  defp ordinary?(_), do: false
end
