defmodule AgentboardWeb.FleetLoadoutController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.{Captain, FleetLoadout, FleetRefill}

  def show(conn, %{"id" => id}),
    do: reply(conn, FleetLoadout.show(id, Captain.authenticate_header(conn)))

  def replace(conn, %{"id" => id}),
    do: reply(conn, FleetLoadout.replace(id, Captain.authenticate_header(conn), conn.body_params))

  def activate(conn, %{"id" => id}),
    do: reply(conn, FleetRefill.activate(id, Captain.authenticate_header(conn), conn.body_params))

  def deactivate(conn, %{"id" => id}),
    do:
      reply(conn, FleetRefill.deactivate(id, Captain.authenticate_header(conn), conn.body_params))

  def refill(conn, %{"id" => id}),
    do: reply(conn, FleetRefill.status(id, Captain.authenticate_header(conn)))

  defp reply(conn, result),
    do:
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> AgentboardWeb.APIController.reply(result)
end
