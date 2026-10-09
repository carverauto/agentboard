defmodule AgentboardWeb.Plugs.FrontendAuth do
  @moduledoc "HTTP human gate. A bridge cookie never substitutes for an Access assertion."
  import Plug.Conn
  alias Agentboard.FrontendAuth
  alias Agentboard.FrontendAuth.Sessions

  def init(options), do: options

  def call(conn, _options) do
    case FrontendAuth.config() do
      {:ok, %{mode: :off}} -> conn
      {:ok, config} -> authenticate(conn, config)
      _ -> reject(conn, :unavailable)
    end
  end

  def revoke_session(conn) do
    Sessions.revoke(get_session(conn, :frontend_auth_id))

    conn
    |> delete_session(:frontend_auth_id)
    |> delete_session(:captain)
  end

  # Used only after the browser pipeline verified this HTTP request. Rotate
  # before assigning a new captain capability, so old tabs lose the old bridge
  # while the next full page load keeps the newly unlocked capability.
  def rotate_session(conn) do
    conn = revoke_session(conn)

    case FrontendAuth.config() do
      {:ok, %{mode: :off}} ->
        {:ok, conn}

      {:ok, config} ->
        case conn.assigns[:frontend_identity] do
          %{subject: _, email: _, jwt_expires_at: _} = principal ->
            case new_bridge(conn, principal, config) do
              {:ok, conn} -> {:ok, conn}
              _ -> {:error, reject(conn, :unavailable)}
            end

          _ ->
            {:error, reject(conn, :unauthorized)}
        end

      _ ->
        {:error, reject(conn, :unavailable)}
    end
  end

  defp authenticate(conn, config) do
    with [token] <- get_req_header(conn, "cf-access-jwt-assertion"),
         {:ok, principal} <- FrontendAuth.verify(token, config),
         {:ok, conn} <- bridge(conn, principal, config) do
      conn
      |> assign(:frontend_identity, principal)
      |> put_resp_header("cache-control", "no-store")
    else
      {:error, reason} -> reject(conn, reason)
      _ -> reject(conn, :unauthorized)
    end
  end

  defp bridge(conn, principal, config) do
    id = get_session(conn, :frontend_auth_id)

    case Sessions.validate(id) do
      {:ok, %{principal: old, expires_at: expiry}}
      when old.subject == principal.subject and old.email == principal.email and
             expiry <= principal.jwt_expires_at ->
        {:ok, conn}

      _ ->
        conn = revoke_session(conn)
        new_bridge(conn, principal, config)
    end
  end

  defp new_bridge(conn, principal, config) do
    case Sessions.issue(principal, config) do
      {:ok, new_id, _} ->
        {:ok,
         conn
         |> configure_session(renew: true)
         |> put_session(:frontend_auth_id, new_id)}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp reject(conn, reason) do
    {status, message} =
      case reason do
        :forbidden -> {403, "This identity is not allowed to access the board."}
        :unavailable -> {503, "Browser authentication is temporarily unavailable."}
        _ -> {401, "Cloudflare Access authentication required."}
      end

    conn
    |> revoke_session()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
    |> halt()
  end
end
