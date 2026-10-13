defmodule AgentboardWeb.FleetHostController do
  @moduledoc "Seat-supply host routes; each request carries the enrolled host's own bearer token."
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.SeatSupply

  def intents(conn, %{"host_id" => host}),
    do: reply(conn, SeatSupply.host_intents(host, bearer(conn)))

  def reserve(conn, %{"host_id" => host, "id" => id}),
    do: reply(conn, SeatSupply.reserve(host, bearer(conn), id))

  def report(conn, %{"host_id" => host, "id" => id}),
    do: reply(conn, SeatSupply.report(host, bearer(conn), id, conn.body_params))

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> value] -> value
      _ -> nil
    end
  end

  defp reply(conn, result),
    do:
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> AgentboardWeb.APIController.reply(result)
end
