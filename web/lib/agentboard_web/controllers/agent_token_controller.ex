defmodule AgentboardWeb.AgentTokenController do
  use Phoenix.Controller, formats: [:json]
  def list(conn, %{"id" => id}), do: administer(conn, id, "list", %{})

  def mutate(conn, %{"id" => id, "action" => action}),
    do: administer(conn, id, action, conn.body_params)

  def report(conn, _), do: AgentboardWeb.APIController.reply(conn, Agentboard.Auth.report())

  def browser_mutate(conn, %{"action" => action} = params) do
    proof = get_session(conn, "captain")

    case Agentboard.Auth.administer(params["agent_id"], action, %{}, proof) do
      {:ok, %{token: token}} ->
        # Regular CSRF-protected POST response: no credential in LiveView state.
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("content-disposition", "attachment; filename=agentboard-token.txt")
        |> put_resp_content_type("text/plain")
        |> send_resp(200, token <> "\n")

      {:ok, _} ->
        redirect(conn, to: "/settings")

      error ->
        AgentboardWeb.APIController.reply(conn, error)
    end
  end

  defp administer(conn, id, action, data) do
    proof =
      Agentboard.Captain.authenticate_header(conn, "x-agentboard-captain-token") ||
        Agentboard.Captain.authenticate_header(conn)

    AgentboardWeb.APIController.reply(conn, Agentboard.Auth.administer(id, action, data, proof))
  end
end
