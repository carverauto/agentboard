defmodule Agentboard.RateLimits do
  @moduledoc """
  Per-replica request/stream admission through atomic ETS operations.

  Checks run in the caller, without GenServer.call or any database access.
  Enforce mode uses IP admission before authentication and a separate verified
  principal budget afterward. Legacy modes retain declared-agent accounting.
  """
  @requests Agentboard.RateLimits.Requests
  @watches Agentboard.RateLimits.Watches

  def settings, do: Application.fetch_env!(:agentboard, :rate_limits)

  def check(ip, agent) do
    config = settings()
    subjects = [{:ip, ip, config[:ip]}]
    subjects = if agent, do: subjects ++ [{:agent, agent, config[:agent]}], else: subjects
    check_subjects(subjects, config)
  end

  # Only call after verifying the credential. This never charges the IP budget
  # again, and the identity must never come from request attribution headers.
  def check_agent(agent) when is_binary(agent) do
    config = settings()
    check_subjects([{:agent, agent, config[:agent]}], config)
  end

  defp check_subjects(subjects, config) do
    window = Keyword.fetch!(config, :window_ms)
    now = System.monotonic_time(:millisecond)
    expires = (Integer.floor_div(now, window) + 1) * window
    retry_after = max(1, Integer.floor_div(expires - now + 999, 1_000))

    Enum.reduce_while(subjects, :ok, fn {scope, identity, limit}, _ ->
      case increment({expires, scope, identity}, config[:max_buckets]) do
        {:ok, count} when count <= limit -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :rate_limited, retry_after}}
        {:error, :unavailable} -> {:halt, {:error, :unavailable}}
      end
    end)
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def reserve_watch(ip, agent) do
    config = settings()
    reference = make_ref()
    :ets.insert(@watches, {reference, ip, agent, self()})

    cond do
      :ets.info(@watches, :size) > config[:max_watches] ->
        release_watch(reference)
        {:error, :unavailable}

      watch_count(1, ip) > config[:watch_ip] or
          (agent != nil and watch_count(2, agent) > config[:watch_agent]) ->
        release_watch(reference)
        {:error, :rate_limited, 1}

      true ->
        {:ok, reference}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def release_watch(reference) do
    :ets.delete(@watches, reference)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp watch_count(1, ip), do: :ets.select_count(@watches, [{{:_, ip, :_, :_}, [], [true]}])
  defp watch_count(2, agent), do: :ets.select_count(@watches, [{{:_, :_, agent, :_}, [], [true]}])

  defp increment(key, max_buckets) do
    if :ets.lookup(@requests, key) == [] do
      reserved = :ets.update_counter(@requests, :size, {2, 1})

      cond do
        reserved > max_buckets ->
          :ets.update_counter(@requests, :size, {2, -1})
          throw(:limiter_capacity)

        not :ets.insert_new(@requests, {key, 0}) ->
          :ets.update_counter(@requests, :size, {2, -1})

        true ->
          :ok
      end
    end

    {:ok, :ets.update_counter(@requests, key, {2, 1})}
  catch
    :limiter_capacity -> {:error, :unavailable}
  end
end
