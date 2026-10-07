defmodule AgentboardWeb.ConversationController do
  @moduledoc "Worker identity enrollment (captain-provisioned) and coverage receipts (worker-attributed)."
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  alias Agentboard.Mattermost.Conversations

  # Provisioning requires the captain token: identities are explicit
  # provisioning, never self-signup.
  def enroll(conn, params) do
    case captain_token(conn) do
      nil ->
        conn |> put_status(422) |> json(%{error: %{code: "invalid_context", message: "Enrollment requires a captain token"}})

      _proof ->
        case params do
          %{"agent_id" => agent_id, "mm_user_id" => user_id} ->
            case Conversations.enroll(agent_id, user_id, params["mm_username"], params["credential_ref"]) do
              {:ok, identity} -> json(conn, identity)
              {:error, "conflict", message} -> conn |> put_status(409) |> json(%{error: %{code: "conflict", message: message}})
              {:error, code, message} when code in ~w(invalid_input invalid_context) -> conn |> put_status(422) |> json(%{error: %{code: code, message: message}})
              {:error, _code, message} -> conn |> put_status(503) |> json(%{error: %{code: "unavailable", message: message}})
            end

          _ ->
            conn |> put_status(422) |> json(%{error: %{code: "invalid_input", message: "agent_id and mm_user_id are required"}})
        end
    end
  end

  def revoke(conn, %{"agent_id" => agent_id} = params) do
    case captain_token(conn) do
      nil ->
        conn |> put_status(422) |> json(%{error: %{code: "invalid_context", message: "Agent revocation requires a captain token"}})

      _proof ->
        case Conversations.revoke(agent_id, params["reason"] || "revoked") do
          {:ok, value} -> json(conn, value)
          {:error, "not_found", message} -> conn |> put_status(404) |> json(%{error: %{code: "not_found", message: message}})
          {:error, code, message} when code in ~w(invalid_input invalid_context) -> conn |> put_status(422) |> json(%{error: %{code: code, message: message}})
          {:error, "conflict", message} -> conn |> put_status(409) |> json(%{error: %{code: "conflict", message: message}})
          {:error, _code, message} -> conn |> put_status(503) |> json(%{error: %{code: "unavailable", message: message}})
        end
    end
  end

  def identity(conn, %{"agent_id" => agent_id}) do
    case Conversations.sender_for(agent_id) do
      {:ok, user_id} -> json(conn, %{agent_id: agent_id, mm_user_id: user_id, status: "enrolled"})
      {:error, status} -> conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "No active identity: #{status}"}})
    end
  end

  # Coverage receipts are worker-attributed like board reads, but the mapping
  # decides: a worker reports only its own coverage.
  def report_coverage(conn, %{"agent_id" => agent_id, "channel_id" => channel_id} = params) do
    with :ok <- authorize_coverage_caller(actor(conn), agent_id) do
      case Conversations.report_coverage(agent_id, channel_id, params["last_post_id"], params["last_version"] || 0,
             caught_up: params["caught_up"] == true,
             incomplete_reason: params["incomplete_reason"]
           ) do
        {:ok, value} ->
          json(conn, value)

        {:error, code, message} when code in ~w(invalid_input invalid_context) ->
          conn |> put_status(422) |> json(%{error: %{code: code, message: message}})

        {:error, "conflict", message} ->
          conn |> put_status(409) |> json(%{error: %{code: "conflict", message: message}})

        {:error, "not_found", message} ->
          conn |> put_status(404) |> json(%{error: %{code: "not_found", message: message}})

        {:error, message} ->
          conn |> put_status(503) |> json(%{error: %{code: "unavailable", message: message}})

        {:error, _code, message} ->
          conn |> put_status(503) |> json(%{error: %{code: "unavailable", message: message}})
      end
    else
      {:error, message} ->
        conn |> put_status(422) |> json(%{error: %{code: "invalid_context", message: message}})
    end
  end

  def coverage(conn, %{"agent_id" => agent_id, "channel_id" => channel_id}) do
    case Conversations.coverage(agent_id, channel_id) do
      {:ok, row} -> json(conn, row)
      {:error, _} -> conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "No coverage reported"}})
    end
  end

  defp captain_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Agentboard.Captain.authenticate(token)
      _ -> nil
    end
  end

  defp actor(conn) do
    Map.new(~w(agent model harness), fn key -> {key, List.first(get_req_header(conn, "x-agentboard-" <> key))} end)
  end

  defp authorize_coverage_caller(caller, agent_id) do
    try do
      agent = Agentboard.Board.Operations.identity!(caller)

      if agent.id == agent_id,
        do: :ok,
        else: {:error, "Workers report only their own coverage"}
    rescue
      _ in Agentboard.Board.OperationError -> {:error, "Register a matching agent identity first"}
    end
  end

end
