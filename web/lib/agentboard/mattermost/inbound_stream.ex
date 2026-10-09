defmodule Agentboard.Mattermost.InboundStream do
  @moduledoc "Owns one lease-fenced shared-bot WebSocket. Supervised REST tasks run while live events buffer. Disabled by default."
  use GenServer
  alias Agentboard.Mattermost.{Inbound, InboundHTTP, InboundStore}
  alias Mint.{HTTP, WebSocket}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  defp empty, do: %{cfg: nil, conn: nil, ref: nil, ws: nil, status: nil, headers: [], hello: false, authenticated: false, seq: nil, task: nil, buffer: [], bytes: 0, channels: [], last_frame: now(), next_scan: now(), frame_bytes: 0, retry_at: now()}
  @impl true
  def init(_) do
    Process.send_after(self(), :tick, 1000)
    {:ok, empty()}
  end

  @impl true
  def handle_info(:tick, state) do
    state = cond do
      not Inbound.enabled?() -> disconnect(state, "disabled")
      is_nil(state.cfg) and now() >= state.retry_at -> connect(state)
      is_nil(state.cfg) -> state
      true -> renew_tick(state)
    end
    Process.send_after(self(), :tick, 5000)
    {:noreply, state}
  end

  defp renew_tick(state) do
    case InboundStore.renew(state.cfg, ready?(state), if(ready?(state), do: "live", else: "authenticating")) do
      {:ok, true} ->
        cond do
          now() - state.last_frame > 30_000 -> disconnect(state, "stream_timeout")
          true ->
            state = if state.ws, do: send_frame(state, :ping), else: state
            if ready?(state) and state.task == nil and now() >= state.next_scan, do: scan(state), else: state
        end
      {:ok, false} -> disconnect(state, "owner_expired")
      {:error, :store_unavailable} -> disconnect(state, "store_unavailable")
    end
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}
    case result do
      {:ok, channels, _} ->
        {allowed, denied} = Enum.split_with(state.buffer, &(&1["channel_id"] in channels))
        Enum.each(denied, fn post -> InboundStore.coverage(state.cfg, post["channel_id"], 0, false, "live_channel_not_authorized") end)
        state = %{state | channels: channels, buffer: allowed, bytes: if(allowed == [], do: 0, else: Enum.reduce(allowed, 0, fn post, acc -> acc + byte_size(Jason.encode!(post)) end)), next_scan: now() + 30_000}
        {:noreply, flush(state)}
      {:live, {:ok, gaps, capacity}, channels} ->
        gaps |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> Enum.each(fn {channel, ids} ->
          reason = String.slice("live_post_gap:" <> Enum.join(ids |> Enum.uniq() |> Enum.take(8), ","), 0, 256)
          InboundStore.coverage(state.cfg, channel, nil, false, reason)
        end)
        if capacity do
          Enum.each(channels, fn channel -> InboundStore.coverage(state.cfg, channel, nil, false, "metadata_capacity_reached") end)
        end
        {:noreply, flush(state)}
      {:live, {:error, {:rate_limited, seconds}}, _} -> {:noreply, %{disconnect(state, "rate_limited", seconds) | retry_at: now() + seconds * 1000}}
      {:live, {:error, :owner_expired}, _} -> {:noreply, disconnect(state, "owner_expired")}
      {:live, {:error, :store_unavailable}, _} -> {:noreply, disconnect(state, "store_unavailable")}
      {:live, _, _} -> {:noreply, disconnect(state, "catch_up_incomplete")}
      {:error, {:rate_limited, seconds}} -> {:noreply, %{disconnect(state, "rate_limited", seconds) | retry_at: now() + seconds * 1000}}
      {:error, :owner_expired} -> {:noreply, disconnect(state, "owner_expired")}
      {:error, :store_unavailable} -> {:noreply, disconnect(state, "store_unavailable")}
      _ -> {:noreply, disconnect(state, "catch_up_incomplete")}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state),
    do: {:noreply, disconnect(%{state | task: nil}, "catch_up_failed")}

  def handle_info(:flush, state), do: {:noreply, flush(state)}
  def handle_info(_, %{conn: nil} = state), do: {:noreply, state}
  def handle_info(message, state) do
    case WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} -> {:noreply, responses(%{state | conn: conn}, responses)}
      :unknown -> {:noreply, state}
      _ -> {:noreply, disconnect(state, "stream_disconnected")}
    end
  end

  defp connect(state) do
    with {:ok, cfg} <- Inbound.base_config(),
         {:ok, cfg} <- InboundStore.claim(cfg) do
      state = %{state | cfg: cfg, last_frame: now()}
      with {:ok, verified} <- Inbound.verify_bot(cfg),
           {:ok, conn, uri, scheme} <- InboundHTTP.connect(verified, :active),
           {:ok, conn, ref} <- WebSocket.upgrade(if(scheme == :https, do: :wss, else: :ws), conn, InboundHTTP.path(uri, "/api/v4/websocket"), []) do
        %{state | cfg: verified, conn: conn, ref: ref}
      else
        {:error, {:rate_limited, seconds}} -> %{disconnect(state, "rate_limited", seconds) | retry_at: now() + seconds * 1000}
        _ -> %{disconnect(state, "stream_identity_or_connect_failed", 30) | retry_at: now() + 30_000}
      end
    else
      {:error, {:rate_limited, seconds}} -> %{state | retry_at: now() + seconds * 1000}
      _ -> state
    end
  end

  # Unexpected OTP errors must not dump the server credential or buffered bodies.
  @impl true
  def format_status(status), do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted)

  defp responses(state, []), do: state
  defp responses(%{cfg: nil} = state, _), do: state
  defp responses(state, [response | rest]) do
    state = case response do
      {:status, ref, status} when ref == state.ref -> %{state | status: status}
      {:headers, ref, headers} when ref == state.ref -> %{state | headers: headers}
      {:done, ref} when ref == state.ref ->
        case WebSocket.new(state.conn, state.ref, state.status, state.headers) do
          {:ok, conn, ws} ->
            %{state | conn: conn, ws: ws}
            |> send_frame({:text, Jason.encode!(%{seq: 1, action: "authentication_challenge", data: %{token: state.cfg.token}})})
          _ -> disconnect(state, "stream_upgrade_rejected")
        end
      {:data, ref, data} when ref == state.ref -> decode(state, data)
      _ -> state
    end
    responses(state, rest)
  end

  defp decode(state, data) do
    # Bound an entire connection, including incomplete fragments/control traffic.
    state = %{state | frame_bytes: state.frame_bytes + byte_size(data)}
    if state.frame_bytes > 16_777_216 or state.ws == nil do
      disconnect(state, "stream_byte_budget")
    else
      case WebSocket.decode(state.ws, data) do
        {:ok, ws, frames} -> Enum.reduce(frames, %{state | ws: ws, last_frame: now()}, &frame/2)
        _ -> disconnect(state, "stream_invalid_frame")
      end
    end
  end

  defp frame(_, %{cfg: nil} = state), do: state
  defp frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp frame({:pong, _}, state), do: state
  defp frame({:close, _, _}, state), do: disconnect(send_frame(state, :close), "stream_closed")
  defp frame({:text, text}, state) when byte_size(text) <= 1_048_576 do
    case Jason.decode(text) do
      {:ok, event} when is_map(event) -> event(state, event)
      _ -> disconnect(state, "stream_invalid_event")
    end
  end
  defp frame(_, state), do: disconnect(state, "stream_invalid_frame")

  defp event(state, %{"seq_reply" => 1, "status" => "OK"}), do: maybe_scan(%{state | authenticated: true})
  defp event(state, %{"seq_reply" => 1}), do: disconnect(state, "stream_auth_rejected")
  defp event(state, %{"event" => kind, "seq" => seq} = event) when is_integer(seq) do
    if state.seq != nil and seq != state.seq + 1 do
      disconnect(state, "stream_sequence_gap")
    else
      state = %{state | seq: seq}
      case kind do
        "hello" -> maybe_scan(%{state | hello: true})
        kind when kind in ["posted", "post_edited", "post_deleted"] -> queue(state, event)
        kind when kind in ["direct_added", "group_added", "channel_created", "channel_deleted", "user_added", "user_removed"] -> %{state | next_scan: now()}
        _ -> state
      end
    end
  end
  defp event(state, %{"event" => _}), do: disconnect(state, "stream_sequence_unverified")
  defp event(state, _), do: state

  defp queue(state, event) do
    post = get_in(event, ["data", "post"])
    with true <- is_binary(post) and byte_size(post) <= 131_072,
         {:ok, decoded} <- Jason.decode(post),
         true <- Inbound.valid_post?(decoded) do
      bytes = state.bytes + byte_size(post)
      if bytes > 4_194_304 or length(state.buffer) >= 4096 do
        disconnect(state, "live_buffer_overflow")
      else
        Process.send_after(self(), :flush, 100)
        %{state | buffer: [decoded | state.buffer], bytes: bytes}
      end
    else
      _ -> drop(state, event)
    end
  end

  defp drop(state, event) do
    decoded = case get_in(event, ["data", "post"]) do
      post when is_binary(post) -> case Jason.decode(post) do {:ok, decoded} when is_map(decoded) -> decoded; _ -> %{} end
      _ -> %{}
    end
    id = if InboundHTTP.segment?(decoded["id"]), do: decoded["id"], else: "invalid_id"
    if is_map(state.cfg) and InboundHTTP.segment?(decoded["channel_id"]) do
      InboundStore.coverage(state.cfg, decoded["channel_id"], nil, false, "live_post_gap:" <> id)
    end
    state
  end

  defp maybe_scan(state), do: if(ready?(state) and state.task == nil, do: scan(state), else: state)
  defp ready?(state), do: state.hello and state.authenticated and state.ws != nil
  defp scan(state) do
    cfg = state.cfg
    task = Task.Supervisor.async_nolink(Agentboard.Mattermost.InboundTasks, fn -> Inbound.reconcile(cfg) end)
    %{state | task: task}
  end
  defp flush(%{buffer: []} = state), do: state
  defp flush(state) do
    cond do
      not ready?(state) or state.task != nil -> state
      Enum.any?(state.buffer, &(&1["channel_id"] not in state.channels)) -> scan(state)
      true ->
        cfg = state.cfg
        posts = Enum.reverse(state.buffer)
        task = Task.Supervisor.async_nolink(Agentboard.Mattermost.InboundTasks, fn ->
          result = Enum.reduce_while(posts, {:ok, [], false}, fn post, {:ok, gaps, _capacity} ->
            case Inbound.observe(cfg, post) do
              {:ok, _} -> {:cont, {:ok, gaps, false}}
              {:error, :metadata_capacity_reached} -> {:halt, {:ok, gaps, true}}
              {:error, :owner_expired} = error -> {:halt, error}
              {:error, :store_unavailable} = error -> {:halt, error}
              {:error, reason} when reason in [:invalid_or_disallowed_post, :thread_root_unavailable] ->
                {:cont, {:ok, [{post["channel_id"], post["id"]} | gaps], false}}
              error -> {:halt, error}
            end
          end)
          channels = posts |> Enum.map(& &1["channel_id"]) |> Enum.uniq() |> Enum.take(8)
          {:live, result, channels}
        end)
        %{state | task: task, buffer: [], bytes: 0}
    end
  end

  defp send_frame(state, frame) do
    with {:ok, ws, bytes} <- WebSocket.encode(state.ws, frame),
         {:ok, conn} <- WebSocket.stream_request_body(state.conn, state.ref, bytes) do
      %{state | ws: ws, conn: conn}
    else
      _ -> disconnect(state, "stream_write_failed")
    end
  end
  defp disconnect(state, reason, delay \\ 0) do
    if state.task, do: Task.Supervisor.terminate_child(Agentboard.Mattermost.InboundTasks, state.task.pid)
    if state.conn, do: HTTP.close(state.conn)
    if state.cfg, do: InboundStore.release(state.cfg, reason, delay)
    empty()
  end
  defp now, do: System.monotonic_time(:millisecond)
end
