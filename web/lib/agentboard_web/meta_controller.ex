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
      required_decision_intake_version: 1,
      decision_conversation_supported: true,
      message_transport: Agentboard.MessageMode.status(),
      schema_version: current,
      required_schema_version: Agentboard.SchemaVersion.required()
    })
  end
end
