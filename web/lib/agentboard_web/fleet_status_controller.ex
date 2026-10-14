defmodule AgentboardWeb.FleetStatusController do
  @moduledoc """
  Bounded fleet status digest (`GET /api/v1/fleet/status`).
  Requires a captain-issued `helper` credential or the captain capability in
  every authentication mode (`off`, `observe`, `enforce`).
  """
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.FleetStatus
  alias AgentboardWeb.APIController
  alias AgentboardWeb.Plugs.AgentAuth

  def show(conn, _) do
    conn = conn |> fetch_query_params() |> put_resp_header("cache-control", "no-store")

    case AgentAuth.authorize_helper(conn) do
      {:halted, conn} ->
        conn

      {:ok, conn, _actor} ->
        APIController.reply(conn, FleetStatus.status(conn.query_params))
    end
  end
end
