defmodule AgentboardWeb.Plugs.Compatibility do
  import Plug.Conn
  def init(options), do: options

  def call(conn, _options) do
    case Agentboard.SchemaVersion.current() do
      {:ok, _} ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          503,
          Jason.encode!(%{
            error: %{
              code: "schema_unavailable",
              message:
                "Board schema is unavailable or incompatible; an operator must run release migrations"
            }
          })
        )
        |> halt()
    end
  end
end

