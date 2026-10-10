defmodule AgentboardWeb.CoordinatorController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.Coordinator
  alias AgentboardWeb.APIController, as: API
  plug(:protocol)

  def tick(conn, _) do
    with :ok <- query_shape(conn) do
      API.reply(conn, Coordinator.tick(principal(conn), fetch_query_params(conn).query_params))
    else
      error -> API.reply(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    if conn.query_string == "",
      do: API.reply(conn, Coordinator.show(principal(conn), id)),
      else:
        API.reply(conn, {:error, "invalid_input", "Exact source reads accept no query options"})
  end

  def ack(conn, _),
    do: API.reply(conn, Coordinator.acknowledge(principal(conn), conn.body_params))

  def heartbeat(conn, _),
    do: API.reply(conn, Coordinator.heartbeat(principal(conn), conn.body_params))

  defp principal(conn), do: conn.assigns[:authenticated_agent]

  defp query_shape(conn) do
    keys = conn.query_string |> URI.query_decoder() |> Enum.map(&elem(&1, 0))

    if byte_size(conn.query_string) <= 8192 and length(keys) == length(Enum.uniq(keys)) and
         Enum.all?(keys, &(&1 in ~w(limit max_bytes cursor))),
       do: :ok,
       else: {:error, "invalid_input", "Bounded unique coordinator query options required"}
  rescue
    _ -> {:error, "invalid_input", "Invalid coordinator query encoding"}
  end

  defp protocol(conn, _) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if get_req_header(conn, "x-agentboard-coordinator-protocol") == ["1"],
      do: conn,
      else:
        conn
        |> API.reply({:error, "invalid_input", "Coordinator protocol revision 1 required"})
        |> halt()
  end
end
