defmodule AgentboardWeb.ConversationController do
  @moduledoc "Agent chat: API-backed send/reads plus coverage receipts. Sends post through the agent's own elastic bot when active, otherwise the shared bot. Agents never hold Mattermost credentials."
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  alias Agentboard.Mattermost.{Conversations, Participation}

  # POST /conversations/send — Agentboard-authenticated agents only. The
  # server posts with the agent's own bot when active, else the shared
  # bot; attribution comes from props.
  # An unresolved spool outcome (`submitting`, `uncertain`, `expired`) is a
  # 202 receipt, never a 200: the post may or may not exist remotely.
  def send(conn, params) do
    result =
      with {:ok, cfg} <- authorize_channel(conn, params["channel_id"]),
           do: Conversations.send_as(actor(conn), params, cfg)

    reply_send(conn, result)
  end

  # GET /conversations/sends?state= — the caller's own spool receipts,
  # metadata only (never bodies; the spool is not a second inbox).
  def sends(conn, params), do: reply(conn, Conversations.sends(actor(conn), params["state"]))

  # GET /conversations/sends/:msg_id — one of the caller's own receipts.
  def send_status(conn, %{"msg_id" => msg_id}),
    do: reply(conn, Conversations.send_status(actor(conn), msg_id))

  # POST /conversations/sends/:msg_id/resolve {"action": reconcile|retry|abandon}
  # Explicit resolution of an unresolved send; retry records a possible duplicate.
  def resolve_send(conn, %{"msg_id" => msg_id} = params) do
    caller = actor(conn)

    result =
      with {:ok, channel_id} <- Conversations.send_channel(caller, msg_id),
           {:ok, cfg} <- authorize_channel(conn, channel_id),
           do: Conversations.resolve_send(caller, msg_id, params["action"], cfg)

    reply_send(conn, result)
  end

  # GET /conversations/reads?channel_id=&since=&limit= — own-echo
  # suppression by props.agent_id; coverage recorded with the read.
  # `inbox=true` reads the caller's own private recipient route instead.
  def reads(conn, params) do
    result =
      with {:ok, cfg} <- authorize_channel(conn, params["channel_id"]),
           do:
             Conversations.reads(
               actor(conn),
               params["channel_id"],
               params["since"],
               params["limit"],
               cfg,
               inbox: params["inbox"] in ["true", "1"]
             )

    reply(conn, result)
  end

  # Explicit coverage receipts; the reporter must be the registered agent
  # in the path, verified against the request identity.
  def report_coverage(conn, %{"agent_id" => agent_id, "channel_id" => channel_id} = params) do
    caller = actor(conn)

    if agent_id == caller["agent"] do
      result =
        with {:ok, _cfg} <- authorize_channel(conn, channel_id) do
          Conversations.report_coverage(
            caller,
            channel_id,
            params["last_post_id"],
            params["last_version"] || 0,
            caught_up: params["caught_up"] == true,
            incomplete_reason: params["incomplete_reason"]
          )
        end

      reply(conn, result)
    else
      conn
      |> put_status(422)
      |> json(%{
        error: %{code: "invalid_context", message: "Workers report only their own coverage"}
      })
    end
  end

  def coverage(conn, %{"agent_id" => agent_id, "channel_id" => channel_id}) do
    result =
      with :ok <- authorize_coverage_identity(conn, agent_id),
           {:ok, _cfg} <- authorize_channel(conn, channel_id),
           do: Conversations.coverage(agent_id, channel_id)

    reply(conn, result)
  end

  # GET /conversations/diagnostics — cached override observations for the
  # calling registered agent. Read-only; carries no secrets.
  def diagnostics(conn, _params) do
    reply(conn, Conversations.diagnostics(actor(conn)))
  end

  defp authorize_coverage_identity(conn, agent_id) do
    case conn.assigns[:authenticated_agent] do
      %{scope: "coordinator_participant", agent_id: id} when id != agent_id ->
        {:error, "forbidden", "Participants may read only their own coverage"}

      _ ->
        :ok
    end
  end

  defp authorize_channel(conn, channel_id) do
    case conn.assigns[:authenticated_agent] do
      %{scope: "coordinator_participant"} = principal ->
        Participation.authorize(principal, channel_id)

      _ ->
        {:ok, nil}
    end
  end

  defp actor(conn), do: AgentboardWeb.APIController.actor(conn)

  defp reply_send(conn, {:ok, value} = result) do
    if Agentboard.Mattermost.ChatSends.unresolved?(value),
      do: conn |> put_status(202) |> json(value),
      else: reply(conn, result)
  end

  defp reply_send(conn, result), do: reply(conn, result)

  defp reply(conn, {:ok, value}), do: json(conn, value)

  defp reply(conn, {:error, code, message}) do
    conn |> put_status(status_for(code)) |> json(%{error: %{code: code, message: message}})
  end

  defp status_for(code) when code in ~w(invalid_input invalid_context), do: 422
  defp status_for("not_found"), do: 404
  defp status_for("forbidden"), do: 403
  defp status_for("unauthorized"), do: 401
  defp status_for("conflict"), do: 409
  defp status_for(_), do: 503
end
