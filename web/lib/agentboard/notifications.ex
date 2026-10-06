defmodule Agentboard.Notifications do
  use GenServer
  @topics ~w(ab_agents ab_tasks ab_messages ab_quota)

  # This process owns one LISTEN connection and its reconnection lifecycle.
  # It never serves queries; subscribers requery in their own pooled caller process.
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    Process.flag(:trap_exit, true)
    {:ok, nil, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)
  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info({:notification, pid, _ref, topic, _payload}, pid) when topic in @topics do
    Phoenix.PubSub.broadcast(Agentboard.PubSub, topic, {:board_changed, topic, :change})
    {:noreply, pid}
  end

  def handle_info({:EXIT, pid, _reason}, pid) do
    Process.send_after(self(), :connect, 1000)
    {:noreply, nil}
  end

  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_reason, pid) when is_pid(pid), do: Process.exit(pid, :shutdown)
  def terminate(_, _), do: :ok

  defp connect(nil) do
    options =
      Agentboard.Repo.config()
      |> Keyword.take([:hostname, :port, :database, :username, :password, :ssl, :socket_options])
      |> Keyword.put(:sync_connect, true)

    case Postgrex.Notifications.start_link(options) do
      {:ok, pid} ->
        try do
          Enum.each(@topics, fn topic -> {:ok, _} = Postgrex.Notifications.listen(pid, topic) end)

          Enum.each(
            @topics,
            &Phoenix.PubSub.broadcast(Agentboard.PubSub, &1, {:board_changed, &1, :reconnect})
          )

          {:noreply, pid}
        catch
          :exit, _ ->
            Process.exit(pid, :shutdown)
            Process.send_after(self(), :connect, 1000)
            {:noreply, nil}
        end

      {:error, _} ->
        Process.send_after(self(), :connect, 1000)
        {:noreply, nil}
    end
  end

  defp connect(state), do: {:noreply, state}
end

