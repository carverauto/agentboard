defmodule AgentboardWeb.DecisionController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.Decisions
  alias AgentboardWeb.APIController, as: API

  def index(conn, _), do: API.reply(conn, Decisions.page(fetch_query_params(conn).query_params))

  def waiting(conn, _),
    do: API.reply(conn, Agentboard.Decisions.Waiting.page(fetch_query_params(conn).query_params))

  def promote(conn, _), do: API.reply(conn, Decisions.promote(actor(conn), conn.body_params))
  def show(conn, %{"id" => id}), do: API.reply(conn, Decisions.show(id))
  def create(conn, _), do: API.reply(conn, Decisions.request(API.actor(conn), conn.body_params))

  def mutate(conn, %{"id" => id, "action" => action}),
    do: API.reply(conn, Decisions.mutate(id, action, actor(conn), conn.body_params))

  def wakes(conn, _), do: API.reply(conn, Decisions.wakes(fetch_query_params(conn).query_params))

  def wake_mutate(conn, %{"id" => id, "action" => action}),
    do: API.reply(conn, Decisions.wake_mutate(id, action, actor(conn), conn.body_params))

  defp actor(conn) do
    proof = Agentboard.Captain.authenticate_header(conn)

    if Agentboard.Captain.authorized?(proof),
      do: Map.put(API.actor(conn), :decision_admin, true),
      else: API.actor(conn)
  end
end
