defmodule Agentboard.FrontendAuth.Sessions do
  @moduledoc """
  Bounded, revocable HTTP-to-LiveView bridges for a single application replica.

  The signed/encrypted browser cookie holds only a random handle. Expiry never
  slides on reconnect or LiveView events. Restarting this process invalidates
  every bridge; callers must reauthenticate over HTTP. Multiple application
  replicas require a shared store before enabling this authentication mode.
  """
  use GenServer
  alias Agentboard.FrontendAuth

  @max_sessions 10_000
  @sweep_ms 30_000

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def issue(principal, config, now \\ System.system_time(:second)) do
    call({:issue, principal, config, now})
  end

  def validate(id, now \\ System.system_time(:second)) do
    with true <- is_binary(id) and byte_size(id) == 43,
         {:ok, %{mode: :cloudflare_access} = config} <- FrontendAuth.config() do
      call({:validate, id, config, now})
    else
      _ -> {:error, :unauthorized}
    end
  end

  def revoke(id) when is_binary(id), do: call({:revoke, id})
  def revoke(_), do: :ok
  def topic(id), do: "frontend-auth:" <> id

  @impl true
  def init(_options) do
    with {:ok, config} <- FrontendAuth.config(),
         :ok <- check_keys(config) do
      Process.send_after(self(), :sweep, @sweep_ms)
      {:ok, %{}}
    else
      _ -> {:stop, :invalid_frontend_auth_configuration}
    end
  end

  @impl true
  def handle_call({:issue, principal, config, now}, _from, sessions) do
    sessions = expire(sessions, now)
    expires_at = min(principal.jwt_expires_at, now + config.session_ttl_seconds)

    if map_size(sessions) < @max_sessions and expires_at > now do
      id = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      session = %{
        principal: principal,
        expires_at: expires_at,
        policy: FrontendAuth.policy_id(config)
      }

      {:reply, {:ok, id, session}, Map.put(sessions, id, session)}
    else
      {:reply, {:error, :unavailable}, sessions}
    end
  end

  def handle_call({:validate, id, config, now}, _from, sessions) do
    case Map.get(sessions, id) do
      %{expires_at: expiry, policy: policy, principal: principal} = session
      when expiry > now ->
        if policy == FrontendAuth.policy_id(config) and FrontendAuth.allowed?(principal, config) do
          {:reply, {:ok, session}, sessions}
        else
          {:reply, {:error, :unauthorized}, Map.delete(sessions, id)}
        end

      _ ->
        {:reply, {:error, :unauthorized}, Map.delete(sessions, id)}
    end
  end

  def handle_call({:revoke, id}, _from, sessions) do
    # Every guard also looks up the handle, so a lost notification never grants
    # another event, parameter update or PubSub disclosure after revocation.
    if Map.has_key?(sessions, id), do: broadcast_revocation(id)
    {:reply, :ok, Map.delete(sessions, id)}
  end

  @impl true
  def handle_info(:sweep, sessions) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, expire(sessions, System.system_time(:second))}
  end

  defp expire(sessions, now),
    do: Map.reject(sessions, fn {_, session} -> session.expires_at <= now end)

  defp check_keys(%{mode: :off}), do: :ok

  defp check_keys(config) do
    case Agentboard.FrontendAuth.Keys.fetch(config.jwks_file, "startup-validation") do
      {:ok, _} -> :ok
      {:error, :unknown_key} -> :ok
      _ -> {:error, :keys_unavailable}
    end
  end

  defp broadcast_revocation(id) do
    Phoenix.PubSub.broadcast(Agentboard.PubSub, topic(id), :frontend_auth_revoked)
  rescue
    _ -> :ok
  end

  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
