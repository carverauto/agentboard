defmodule AgentboardWeb.FleetLoadoutController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.{Captain, FleetLoadout}

  def show(conn, %{"id" => id}),
    do: reply(conn, FleetLoadout.show(id, Captain.authenticate_header(conn)))

  def replace(conn, %{"id" => id}),
    do: reply(conn, FleetLoadout.replace(id, Captain.authenticate_header(conn), conn.body_params))

  defp reply(conn, result),
    do:
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> AgentboardWeb.APIController.reply(result)
end
