defmodule AgentboardWeb.APIController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.Board

  def context_search(conn, _),
    do: reply(conn, Agentboard.Context.search(fetch_query_params(conn).query_params))

  def context_feed(conn, _),
    do: reply(conn, Agentboard.Context.feed(actor(conn), fetch_query_params(conn).query_params))

  def context_show(conn, %{"id" => id}), do: reply(conn, Agentboard.Context.show(id))

  def context_publish(conn, _),
    do: reply(conn, Agentboard.Context.publish(actor(conn), conn.body_params))

  def context_ack(conn, %{"id" => id}),
    do: reply(conn, Agentboard.Context.acknowledge(actor(conn), id))

  def documents(conn, %{"id" => id}), do: reply(conn, Agentboard.Documents.list(id))

  def push_document(conn, %{"id" => id}),
    do: reply(conn, Agentboard.Documents.push(id, actor(conn), conn.body_params))

  def prs(conn, _),
    do: reply(conn, Agentboard.Delivery.Reads.list(fetch_query_params(conn).query_params))

  def resolve_conflict_source(conn, _),
    do:
      reply(
        conn,
        Agentboard.Delivery.ConflictOrders.resolve_source(actor(conn), conn.body_params)
      )

  def bind_publication(conn, _),
    do: reply(conn, Agentboard.Delivery.Publication.bind(actor(conn), conn.body_params))

  def pr(conn, %{"id" => id}), do: reply(conn, Agentboard.Delivery.Reads.detail(id))

  def duplicate_decision(conn, %{"id" => id}),
    do:
      reply(
        conn,
        Agentboard.Delivery.Duplicates.request_decision(id, actor(conn), conn.body_params)
      )

  def quota(conn, _), do: list(conn, "quota")
  def push_quota(conn, _), do: reply(conn, Agentboard.Quota.push(actor(conn), conn.body_params))
  def agents(conn, _), do: list(conn, "agents")
  def availability(conn, _), do: reply(conn, Agentboard.Availability.list())

  def seat_scope(conn, %{"id" => id}), do: reply(conn, Agentboard.SeatScope.show(id))

  def set_seat_scope(conn, %{"id" => id}),
    do: reply(conn, Agentboard.SeatScope.set(id, privileged_actor(conn), conn.body_params))

  def set_availability(conn, _),
    do: reply(conn, Agentboard.Availability.set(privileged_actor(conn), conn.body_params))

  def broadcast_orders(conn, _),
    do: reply(conn, Agentboard.Availability.broadcast(privileged_actor(conn), conn.body_params))

  def tasks(conn, _), do: list(conn, "tasks")

  def agent(conn, %{"id" => id}),
    do: reply(conn, Board.show("agents", id, fetch_query_params(conn).query_params))

  def task(conn, %{"id" => id}),
    do: reply(conn, Board.show("tasks", id, fetch_query_params(conn).query_params))

  def register(conn, _), do: reply(conn, Board.register(actor(conn), conn.body_params))
  def create(conn, _), do: reply(conn, Board.create(actor(conn), conn.body_params))

  def edit(conn, %{"id" => id}),
    do: reply(conn, Board.mutate(id, "edit", actor(conn), conn.body_params))

  def mutate(conn, %{"id" => id, "action" => action}),
    do: reply(conn, Board.mutate(id, action, privileged_actor(conn), conn.body_params))

  def heartbeat(conn, %{"id" => id}),
    do: reply(conn, Board.heartbeat(id, actor(conn), conn.body_params))

  def retire(conn, %{"id" => id}),
    do: reply(conn, Board.retire(id, privileged_actor(conn), conn.body_params))

  def restore(conn, %{"id" => id}),
    do: reply(conn, Board.restore(id, privileged_actor(conn), conn.body_params))

  def send_message(conn, _) do
    authentication =
      cond do
        conn.assigns[:api_auth_kind] == :captain ->
          "captain"

        Agentboard.Auth.mode() == "enforce" and is_map(conn.assigns[:authenticated_agent]) ->
          "authenticated_agent"

        true ->
          "unverified_attribution"
      end

    reply(
      conn,
      Board.message(
        nil,
        Map.put(actor(conn), :triage_authentication, authentication),
        conn.body_params
      )
    )
  end

  def message(conn, %{"id" => id}), do: exact_message(conn, id, false)
  def message_triage(conn, %{"id" => id}), do: exact_message(conn, id, true)

  defp exact_message(conn, id, triage?) do
    conn = fetch_query_params(conn) |> put_resp_header("cache-control", "no-store")

    result =
      with {:ok, %{"message" => message} = value} <- Board.show("messages", id, conn.query_params),
           :ok <- authorize_message(conn, message) do
        if triage?, do: Agentboard.CoordinatorTriage.show(message["id"]), else: {:ok, value}
      end

    reply(conn, result)
  end

  defp authorize_message(conn, message) do
    case conn.assigns[:authenticated_agent] do
      %{scope: "coordinator", agent_id: id} ->
        if message["recipient_id"] == id,
          do: :ok,
          else: {:error, "not_found", "Message not found"}

      _ ->
        :ok
    end
  end

  def read_message(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> reply(conn, Board.message(n, actor(conn), conn.body_params))
      _ -> reply(conn, {:error, "invalid_input", "Message ID must be positive"})
    end
  end

  def messages(conn, _) do
    conn = fetch_query_params(conn)

    with {:ok, filters} <- message_filters(conn, "messages"),
         do: reply(conn, Board.page("messages", filters)),
         else: (error -> reply(conn, error))
  end

  def message_filters(conn, "messages") do
    params = conn.query_params

    cond do
      Map.has_key?(params, "task") or Map.has_key?(params, "to") ->
        {:ok, params}

      Agentboard.Input.slug?(actor(conn)["agent"]) ->
        {:ok, Map.put(params, "to", actor(conn)["agent"])}

      true ->
        {:error, "invalid_context", "Inbox reads require an agent ID or destination filter"}
    end
  end

  def message_filters(conn, _), do: {:ok, conn.query_params}

  def actor(conn), do: AgentboardWeb.Plugs.AgentAuth.actor(conn)

  defp privileged_actor(conn) do
    proof = Agentboard.Captain.authenticate_header(conn)

    if Agentboard.Captain.authorized?(proof),
      do: Map.put(actor(conn), :availability_admin, true),
      else: actor(conn)
  end

  defp list(conn, resource),
    do: reply(conn, Board.page(resource, fetch_query_params(conn).query_params))

  def reply(conn, {:ok, value}), do: json(conn, value)

  def reply(conn, {:error, code, message}) do
    status =
      case code do
        c when c in ~w(invalid_input invalid_context) -> 422
        "not_found" -> 404
        c when c in ~w(conflict stale_order) -> 409
        "forbidden" -> 403
        "unauthorized" -> 401
        _ -> 503
      end

    conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
  end
end
