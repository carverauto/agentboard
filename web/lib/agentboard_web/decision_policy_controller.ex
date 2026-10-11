defmodule AgentboardWeb.DecisionPolicyController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.{Captain, DecisionPolicy}
  alias AgentboardWeb.APIController, as: API

  def index(conn, _), do: reply(conn, DecisionPolicy.list())
  def show(conn, %{"id" => id}), do: reply(conn, DecisionPolicy.show(id))
  def validate(conn, _), do: reply(conn, DecisionPolicy.validate(conn.body_params))
  def plan(conn, _), do: reply(conn, DecisionPolicy.plan(conn.body_params))
  def explain(conn, %{"id" => id}), do: reply(conn, DecisionPolicy.explain(id, conn.body_params))

  def ledger(conn, _),
    do: reply(conn, DecisionPolicy.ledger(fetch_query_params(conn).query_params))

  def draft(conn, _), do: reply(conn, DecisionPolicy.draft(proof(conn), conn.body_params))

  def approve(conn, %{"id" => id}),
    do: reply(conn, DecisionPolicy.approve(id, proof(conn), conn.body_params))

  def activate(conn, %{"id" => id}),
    do: reply(conn, DecisionPolicy.activate(id, proof(conn), conn.body_params))

  def deactivate(conn, _),
    do: reply(conn, DecisionPolicy.deactivate(proof(conn), conn.body_params))

  def apply(conn, %{"id" => id}),
    do: reply(conn, DecisionPolicy.apply(id, proof(conn), conn.body_params))

  defp proof(conn), do: Captain.authenticate_header(conn)

  defp reply(conn, result),
    do: conn |> put_resp_header("cache-control", "no-store") |> API.reply(result)
end
