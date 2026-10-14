defmodule AgentboardWeb.IntakeController do
  @moduledoc """
  Work intake routes. Unavailable while `AGENTBOARD_INTAKE_ENABLED` is off.
  Filing, status and cancel accept a captain-issued `helper` credential or the
  captain capability in every auth mode; reconcile and abandon remain
  captain-only.
  """
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.{Captain, Intake, RateLimits}
  alias AgentboardWeb.APIController
  alias AgentboardWeb.Plugs.AgentAuth

  @captain %{"agent" => "captain", "model" => "human", "harness" => "captain"}

  def create(conn, _), do: guarded(conn, :write, :helper, &Intake.file(&1, conn.body_params))

  def import_issues(conn, _),
    do: guarded(conn, :write, :helper, &Intake.import_issues(&1, conn.body_params))

  def show(conn, %{"id" => id}), do: guarded(conn, :read, :helper, &Intake.show(id, &1))

  def cancel(conn, %{"id" => id}),
    do: guarded(conn, :write, :helper, &Intake.cancel(id, &1, conn.body_params))

  def resolve(conn, %{"id" => id, "item_id" => item_id, "action" => action}),
    do: guarded(conn, :write, :captain, &Intake.resolve(id, item_id, action, &1))

  defp guarded(conn, access, boundary, operation) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if not Intake.enabled?() do
      conn
      |> put_status(404)
      |> json(%{
        error: %{code: "intake_disabled", message: "Work intake is disabled on this server"}
      })
    else
      case authorize(conn, boundary) do
        {:halted, conn} ->
          conn

        {:error, code, message} ->
          APIController.reply(conn, {:error, code, message})

        {:ok, conn, actor} ->
          run_guarded(conn, access, actor, operation)
      end
    end
  end

  defp authorize(conn, :captain) do
    if Captain.authorized?(Captain.authenticate_header(conn)),
      do: {:ok, conn, @captain},
      else: {:error, "forbidden", "Captain capability required"}
  end

  defp authorize(conn, :helper), do: AgentAuth.authorize_helper(conn)

  defp run_guarded(conn, :write, actor, operation) do
    case RateLimits.check_intake(actor["agent"]) do
      :ok ->
        APIController.reply(conn, operation.(actor))

      {:error, :rate_limited, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(429)
        |> json(%{error: %{code: "rate_limited", message: "Intake write limit exceeded"}})

      {:error, :unavailable} ->
        APIController.reply(conn, {:error, "unavailable", "API limiter unavailable"})
    end
  end

  defp run_guarded(conn, :read, actor, operation),
    do: APIController.reply(conn, operation.(actor))
end
