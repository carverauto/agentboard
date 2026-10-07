defmodule AgentboardWeb.ConversationController do
  @moduledoc "Phase 1 shared-bot agent chat: API-backed send/reads plus coverage receipts. Agents never hold Mattermost credentials."
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  alias Agentboard.Mattermost.Conversations

  # POST /conversations/send — Agentboard-authenticated agents only. The
  # server posts with the shared bot; attribution comes from props.
  def send(conn, params) do
    reply(conn, Conversations.send_as(actor(conn), params))
  end

  # GET /conversations/reads?channel_id=&since=&limit= — own-echo
  # suppression by props.agent_id; coverage recorded with the read.
  def reads(conn, params) do
    reply(conn, Conversations.reads(actor(conn), params["channel_id"], params["since"], params["limit"]))
  end

  # Explicit coverage receipts; the reporter must be the registered agent
  # in the path, verified against the request identity.
  def report_coverage(conn, %{"agent_id" => agent_id, "channel_id" => channel_id} = params) do
    caller = actor(conn)

    if agent_id == caller["agent"] do
      reply(conn, Conversations.report_coverage(caller, channel_id, params["last_post_id"], params["last_version"] || 0,
        caught_up: params["caught_up"] == true,
        incomplete_reason: params["incomplete_reason"]
      ))
    else
      conn |> put_status(422) |> json(%{error: %{code: "invalid_context", message: "Workers report only their own coverage"}})
    end
  end

  def coverage(conn, %{"agent_id" => agent_id, "channel_id" => channel_id}) do
    case Conversations.coverage(agent_id, channel_id) do
      {:ok, row} -> json(conn, row)
      {:error, code, message} -> conn |> put_status(status_for(code)) |> json(%{error: %{code: code, message: message}})
    end
  end

  defp actor(conn) do
    Map.new(~w(agent model harness), fn key -> {key, List.first(get_req_header(conn, "x-agentboard-" <> key))} end)
  end

  defp reply(conn, {:ok, value}), do: json(conn, value)

  defp reply(conn, {:error, code, message}) do
    conn |> put_status(status_for(code)) |> json(%{error: %{code: code, message: message}})
  end

  defp status_for(code) when code in ~w(invalid_input invalid_context), do: 422
  defp status_for("not_found"), do: 404
  defp status_for("conflict"), do: 409
  defp status_for(_), do: 503
end
