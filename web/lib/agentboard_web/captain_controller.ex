defmodule AgentboardWeb.CaptainController do
  use Phoenix.Controller, formats: [:html, :json]
  alias Agentboard.{Captain, Housekeeping}

  def unlock(conn, params) do
    case Captain.authenticate(params["token"]) do
      nil ->
        conn
        |> put_status(403)
        |> html("Captain capability rejected. <a href='/settings'>Return to settings</a>")

      capability ->
        case AgentboardWeb.Plugs.FrontendAuth.rotate_session(conn) do
          {:ok, conn} ->
            conn
            |> configure_session(renew: true)
            |> put_session(:captain, capability)
            |> redirect(to: "/settings")

          {:error, conn} ->
            conn
        end
    end
  end

  def lock(conn, _),
    do:
      conn
      |> AgentboardWeb.Plugs.FrontendAuth.revoke_session()
      |> delete_session(:captain)
      |> redirect(to: "/settings")

  def settings(conn, _) do
    if Agentboard.Auth.mode() == "enforce",
      do: authorized(conn, fn -> Housekeeping.settings() end),
      else: AgentboardWeb.APIController.reply(conn, Housekeeping.settings())
  end

  def save(conn, _),
    do: authorized(conn, fn -> Housekeeping.save(Captain.actor(), conn.body_params) end)

  def archive(conn, %{"id" => id}), do: change(conn, id, true)
  def restore(conn, %{"id" => id}), do: change(conn, id, false)

  defp change(conn, id, archived?),
    do:
      authorized(conn, fn ->
        Housekeeping.change(id, archived?, conn.body_params["revision"], Captain.actor())
      end)

  defp authorized(conn, fun) do
    capability = Captain.authenticate_header(conn)

    if Captain.authorized?(capability),
      do: AgentboardWeb.APIController.reply(conn, fun.()),
      else:
        conn
        |> put_status(403)
        |> json(%{error: %{code: "forbidden", message: "Captain capability required"}})
  end
end
