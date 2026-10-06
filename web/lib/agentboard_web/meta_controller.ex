defmodule AgentboardWeb.MetaController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    current =
      case Agentboard.SchemaVersion.current() do
        {:ok, version} -> version
        _ -> nil
      end

    json(conn, %{
      api_version: 1,
      schema_version: current,
      required_schema_version: Agentboard.SchemaVersion.required()
    })
  end
end

