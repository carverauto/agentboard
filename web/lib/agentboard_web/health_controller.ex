defmodule AgentboardWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  def live(conn, _params), do: json(conn, %{status: "live"})

  def ready(conn, _params) do
    case Agentboard.SchemaVersion.current() do
      {:ok, version} -> json(conn, %{status: "ready", schema_version: version})
      {:error, :unavailable} -> conn |> put_status(503) |> json(%{status: "unavailable"})
    end
  end
end

