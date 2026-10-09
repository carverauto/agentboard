defmodule AgentboardWeb.WatchController do
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.{Board, RateLimits}

  def quota(conn, _), do: watch(conn, "quota")
  def tasks(conn, _), do: watch(conn, "tasks")
  def messages(conn, _), do: watch(conn, "messages")

  defp watch(conn, resource) do
    conn = fetch_query_params(conn)
    filters = AgentboardWeb.APIController.message_filters(conn, resource)
    agent = AgentboardWeb.APIController.actor(conn)["agent"]

    with true <- Agentboard.Input.slug?(agent),
         {:ok, filters} <- filters,
         {:ok, reservation} <- RateLimits.reserve_watch(conn.remote_ip, agent) do
      topic = "ab_" <> resource
      Phoenix.PubSub.subscribe(Agentboard.PubSub, topic)

      try do
        case Board.snapshot(resource, filters) do
          {:ok, snapshot} ->
            conn =
              conn
              |> put_resp_content_type("application/x-ndjson")
              |> put_resp_header("cache-control", "no-store")
              |> send_chunked(200)

            emit(conn, topic, snapshot, :initial, resource, filters)

          error ->
            AgentboardWeb.APIController.reply(conn, error)
        end
      after
        Phoenix.PubSub.unsubscribe(Agentboard.PubSub, topic)
        RateLimits.release_watch(reservation)
      end
    else
      false ->
        AgentboardWeb.APIController.reply(
          conn,
          {:error, "invalid_context", "Watches require an agent ID"}
        )

      {:error, :rate_limited, seconds} ->
        throttled(conn, seconds)

      {:error, :unavailable} ->
        AgentboardWeb.APIController.reply(
          conn,
          {:error, "unavailable", "Watch capacity is unavailable"}
        )

      error ->
        AgentboardWeb.APIController.reply(conn, error)
    end
  end

  defp throttled(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_resp_header("cache-control", "no-store")
    |> put_status(429)
    |> json(%{error: %{code: "rate_limited", message: "Watch capacity exceeded"}})
  end

  defp emit(conn, topic, snapshot, reason, resource, filters) do
    payload =
      Map.merge(snapshot, %{
        "topic" => topic,
        "kind" => "snapshot",
        "reason" => Atom.to_string(reason),
        "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    case chunk(conn, Jason.encode!(payload) <> "\n") do
      {:ok, conn} ->
        loop(conn, topic, resource, filters, System.monotonic_time(:millisecond) + 5000)

      {:error, _} ->
        conn
    end
  end

  defp loop(conn, topic, resource, filters, deadline) do
    # Whitespace between JSON snapshots keeps the transport observable without
    # issuing extra SQL. A closed peer releases its reservation on send failure.
    reason =
      receive do
        {:board_changed, ^topic, reason} -> coalesce(topic, reason)
      after
        1000 ->
          if System.monotonic_time(:millisecond) >= deadline, do: :fallback, else: :keepalive
      end

    if reason == :keepalive do
      case chunk(conn, " ") do
        {:ok, conn} -> loop(conn, topic, resource, filters, deadline)
        {:error, _} -> conn
      end
    else
      if AgentboardWeb.Plugs.AgentAuth.stream_authorized?(conn) do
        case Board.snapshot(resource, filters) do
          {:ok, snapshot} -> emit(conn, topic, snapshot, reason, resource, filters)
          {:error, _, _} -> conn
        end
      else
        conn
      end
    end
  end

  defp coalesce(topic, reason) do
    receive do
      {:board_changed, ^topic, next} ->
        coalesce(topic, if(next == :reconnect, do: :reconnect, else: reason))
    after
      0 -> reason
    end
  end
end
