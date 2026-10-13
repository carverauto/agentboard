defmodule AgentboardWeb.FleetLoadoutController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.{Captain, FleetLoadout, FleetRefill, SeatSupply}

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

  def supply(conn, %{"id" => id}),
    do: reply(conn, SeatSupply.status(id, Captain.authenticate_header(conn)))

  def abandon(conn, %{"id" => id, "intent_id" => intent}),
    do:
      reply(
        conn,
        SeatSupply.abandon(id, Captain.authenticate_header(conn), intent, conn.body_params)
      )

  def enroll_host(conn, %{"host_id" => host}),
    do:
      reply(
        conn,
        SeatSupply.enroll_host(host, Captain.authenticate_header(conn), conn.body_params)
      )

  defp reply(conn, result),
    do:
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> AgentboardWeb.APIController.reply(result)
end
