defmodule AgentboardWeb.DecisionConversationController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.Mattermost.DecisionConversations, as: Conversations
  alias AgentboardWeb.APIController, as: API

  def notify(conn, %{"id" => id}),
    do: API.reply(conn, Conversations.notify(principal(conn), id, conn.body_params))

  def reply(conn, %{"id" => id}),
    do: API.reply(conn, Conversations.reply(principal(conn), id, conn.body_params))

  def show(conn, %{"id" => id}), do: API.reply(conn, Conversations.show(principal(conn), id))

  def reconcile(conn, %{"id" => id}),
    do: API.reply(conn, Conversations.reconcile(principal(conn), id, conn.body_params))

  defp principal(conn), do: conn.assigns[:authenticated_agent]
end
