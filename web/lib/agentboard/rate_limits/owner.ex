defmodule Agentboard.RateLimits.Owner do
  @moduledoc "ETS lifecycle/expiry owner; never handles synchronous request checks or SQL."
  use GenServer

  @requests Agentboard.RateLimits.Requests
  @watches Agentboard.RateLimits.Watches

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@requests, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(@requests, {:size, 0})

    :ets.new(@watches, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    removed = :ets.select_delete(@requests, [{{{:"$1", :_, :_}, :_}, [{:<, :"$1", now}], [true]}])
    :ets.update_counter(@requests, :size, {2, -removed})

    :ets.foldl(
      fn {reference, _ip, _agent, pid}, acc ->
        unless Process.alive?(pid), do: Agentboard.RateLimits.release_watch(reference)
        acc
      end,
      :ok,
      @watches
    )

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    interval = min(30_000, Agentboard.RateLimits.settings()[:window_ms])
    Process.send_after(self(), :cleanup, interval)
  end
end

