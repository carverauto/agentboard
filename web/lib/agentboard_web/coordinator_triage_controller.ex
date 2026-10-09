defmodule AgentboardWeb.CoordinatorTriageController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.{Captain, CoordinatorTriage}

  def show(conn, _) do
    result =
      if Captain.authorized?(Captain.authenticate_header(conn)),
        do: CoordinatorTriage.configuration(),
        else: {:error, "forbidden", "Verified captain capability required"}

    reply(conn, result)
  end

  def replace(conn, _) do
    result =
      if Captain.authorized?(Captain.authenticate_header(conn)) do
        actor = %{
          "agent" => "captain",
          "model" => "human",
          "harness" => "captain",
          :triage_admin => true
        }

        CoordinatorTriage.configure(actor, conn.body_params)
      else
        {:error, "forbidden", "Verified captain capability required"}
      end

    reply(conn, result)
  end

  defp reply(conn, result),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> AgentboardWeb.APIController.reply(result)
end
