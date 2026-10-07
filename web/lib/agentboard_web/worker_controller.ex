defmodule AgentboardWeb.WorkerController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.Cooperation.Runtime

  def provision(conn, _), do: captain(conn, fn -> Runtime.provision(conn.body_params) end)

  def resolve_attempt(conn, %{"worker_id" => id}),
    do: captain(conn, fn -> Runtime.resolve_attempt(id, conn.body_params) end)

  def responsibility(conn, %{"id" => id}),
    do:
      captain(conn, fn ->
        Agentboard.Delivery.Accountability.responsibility(id, conn.body_params)
      end)

  def revoke(conn, %{"worker_id" => id}), do: captain(conn, fn -> Runtime.revoke(id) end)

  def operate(conn, params) do
    operation = params["operation"]
    operation = if operation == "state" and conn.method == "POST", do: "report", else: operation

    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> value] -> value
        _ -> nil
      end

    data =
      if conn.method == "GET", do: fetch_query_params(conn).query_params, else: conn.body_params

    data =
      if params["attempt_id"], do: Map.put(data, "attempt_id", params["attempt_id"]), else: data

    protocol(conn, fn -> Runtime.request(params["worker_id"], token, operation, data) end)
  end

  defp captain(conn, fun) do
    capability =
      case get_req_header(conn, "x-agentboard-captain-token") do
        [value] -> Agentboard.Captain.authenticate(value)
        _ -> nil
      end

    if Agentboard.Captain.authorized?(capability),
      do: protocol(conn, fun),
      else: reply(conn, {:error, "forbidden", "Captain capability required"})
  end

  defp protocol(conn, fun) do
    if get_req_header(conn, "x-agentboard-worker-protocol") == ["1"],
      do: reply(conn, fun.()),
      else: reply(conn, {:error, "protocol_mismatch", "Worker protocol revision 1 required"})
  end

  defp reply(conn, {:ok, value}), do: json(conn, Map.put(value, :protocol_revision, 1))

  defp reply(conn, {:error, code, message}) do
    status =
      case code do
        "unauthorized" -> 401
        "forbidden" -> 403
        "not_found" -> 404
        "conflict" -> 409
        c when c in ~w(invalid_input invalid_context protocol_mismatch) -> 422
        _ -> 503
      end

    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}, protocol_revision: 1})
  end
end
