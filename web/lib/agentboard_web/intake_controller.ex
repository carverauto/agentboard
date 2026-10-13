defmodule AgentboardWeb.IntakeController do
  @moduledoc """
  Work intake routes. Unavailable while `AGENTBOARD_INTAKE_ENABLED` is off.
  Each route verifies the captain capability itself, so intake stays
  authenticated even when board-wide agent auth is off; scoped helper
  credentials are a later lane.
  """
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.{Captain, Intake, RateLimits}
  alias AgentboardWeb.APIController

  @captain %{"agent" => "captain", "model" => "human", "harness" => "captain"}

  def create(conn, _), do: guarded(conn, :write, &Intake.file(&1, conn.body_params))

  def show(conn, %{"id" => id}), do: guarded(conn, :read, &Intake.show(id, &1))

  def cancel(conn, %{"id" => id}),
    do: guarded(conn, :write, &Intake.cancel(id, &1, conn.body_params))

  def resolve(conn, %{"id" => id, "item_id" => item_id, "action" => action}),
    do: guarded(conn, :write, &Intake.resolve(id, item_id, action, &1))

  defp guarded(conn, access, operation) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    cond do
      not Intake.enabled?() ->
        conn
        |> put_status(404)
        |> json(%{
          error: %{code: "intake_disabled", message: "Work intake is disabled on this server"}
        })

      not Captain.authorized?(Captain.authenticate_header(conn)) ->
        APIController.reply(conn, {:error, "forbidden", "Captain capability required"})

      access == :write ->
        case RateLimits.check_intake(@captain["agent"]) do
          :ok ->
            APIController.reply(conn, operation.(@captain))

          {:error, :rate_limited, seconds} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(seconds))
            |> put_status(429)
            |> json(%{error: %{code: "rate_limited", message: "Intake write limit exceeded"}})

          {:error, :unavailable} ->
            APIController.reply(conn, {:error, "unavailable", "API limiter unavailable"})
        end

      true ->
        APIController.reply(conn, operation.(@captain))
    end
  end
end
