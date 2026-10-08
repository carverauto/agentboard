defmodule Agentboard.Mattermost.ElasticBots do
  @moduledoc """
  Phase 2 elastic per-agent bots. `ensure/1` is called from the register
  path (never fails registration); provisioning runs in an Oban job so
  Mattermost latency or outages never touch board writes. `retire/1` is
  the roster-GC hook: idempotent, never raises. Agents keep the same
  chat interface and never hold credentials; without a provisioner
  credential or cloak key everything stays on the phase 1 shared bot.
  """
  alias Agentboard.Board.Operations
  alias Agentboard.Mattermost.{AgentBot, Transport}
  require Ash.Query

  @actor %{"agent" => "mattermost-elastic-bots", "model" => "system", "harness" => "ash"}
  @max_username 22

  # Best-effort entry from the register path. Never raises, never fails
  # the caller: without provisioner/cloak material this is a no-op and
  # the agent stays on the shared bot.
  def ensure(agent_id) when is_binary(agent_id) and agent_id != "" do
    if provisionable?() do
      case fetch_bot(agent_id) do
        nil ->
          open_pending(agent_id)
          enqueue_bot_job("provision", agent_id)

        %{state: "retired"} = row ->
          Operations.update(row, :mark_stale, Map.merge(%{state: "pending", last_error: nil}, touched()), @actor)
          enqueue_bot_job("provision", agent_id)

        %{state: "pending"} ->
          enqueue_bot_job("provision", agent_id)

        %{state: "stale"} ->
          enqueue_bot_job("provision", agent_id)

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def ensure(_), do: :ok

  # Roster-GC hook. Idempotent and total: local state moves to retired
  # with the token dropped FIRST (leakage containment), then remote
  # disable plus revocation run best-effort with a retry job covering
  # the remainder. Never raises so GC never blocks on Mattermost.
  def retire(agent_id) when is_binary(agent_id) and agent_id != "" do
    case fetch_bot(agent_id) do
      nil ->
        :ok

      %{state: "retired"} ->
        :ok

      row ->
        Operations.update(row, :retire, Map.merge(%{state: "retired", token: nil, last_error: nil}, touched()), @actor)
        case retire_remote(row) do
          :ok -> :ok
          _ -> enqueue_bot_job("retire", row.agent_id)
        end
        :ok
    end
  rescue
    _ -> :ok
  end

  def retire(_), do: :ok

  # Plaintext token for one send. Only active rows qualify; decrypt
  # failures mark the row stale so the next send re-provisions.
  def token_for(agent_id) do
    case fetch_bot(agent_id) do
      %{state: "active"} = row ->
        case load_token(row) do
          {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
          _ ->
            mark_stale(row, "token_unreadable")
            reprovision(agent_id) |> error()
        end

      %{state: "stale"} ->
        reprovision(agent_id)
        {:error, :no_bot}

      _ ->
        {:error, :no_bot}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  # Diagnostics shape. No secrets: username and state only.
  def bot_info(agent_id) do
    case fetch_bot(agent_id) do
      %{state: state, mm_username: username} ->
        %{"active" => state == "active", "username" => username, "state" => state}

      _ ->
        %{"active" => false, "username" => nil, "state" => nil}
    end
  rescue
    _ -> %{"active" => false, "username" => nil, "state" => nil}
  end

  # Deterministic Mattermost username for an agent id. Always starts
  # with a letter, keeps only valid characters, fits 22 chars, and
  # folds a hash suffix when the id is too long.
  def short_name(agent_id) when is_binary(agent_id) do
    clean = clean_handle(agent_id)
    full = "ab-" <> clean

    if String.length(full) <= @max_username do
      full
    else
      suffix = :crypto.hash(:sha256, agent_id) |> Base.encode16(case: :lower) |> String.slice(0, 6)
      keep = @max_username - 3 - 1 - 6
      head = clean |> String.slice(0, keep) |> String.trim_trailing("-") |> String.trim_trailing(".")
      "ab-" <> head <> "-" <> suffix
    end
  end

  defp clean_handle(agent_id) do
    clean =
      agent_id
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9.\-_]/, "-")
      |> String.trim_trailing("-")
      |> String.trim_trailing(".")

    if clean == "", do: "agent", else: clean
  end

  # Collision-checked variant: a username taken by another agent gets
  # the hashed form so both stay distinct and deterministic.
  def unique_username(agent_id) do
    candidate = short_name(agent_id)

    case fetch_username(candidate) do
      nil -> candidate
      %{agent_id: ^agent_id} -> candidate
      _ -> hashed_username(agent_id)
    end
  end

  defp hashed_username(agent_id) do
    suffix =
      :crypto.hash(:sha256, "agentboard-bot:" <> agent_id)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 10)

    keep = @max_username - 3 - 1 - 10
    head = agent_id |> clean_handle() |> String.slice(0, keep) |> String.trim_trailing("-") |> String.trim_trailing(".")
    "ab-" <> head <> "-" <> suffix
  end

  # Re-enqueue provisioning for a stale row (e.g. after a revoked
  # token). Never raises.
  def reprovision(agent_id) when is_binary(agent_id) do
    enqueue_bot_job("provision", agent_id)
  rescue
    _ -> :ok
  end

  def reprovision(_), do: :ok

  # Send-path report: the bot token was rejected, so the row goes stale
  # and re-provisions in the background while this send falls back.
  # Never raises.
  def note_revoked(agent_id) when is_binary(agent_id) do
    case fetch_bot(agent_id) do
      %{state: "active"} = row ->
        mark_stale(row, "token_revoked")
        reprovision(agent_id)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def note_revoked(_), do: :ok

  # The Oban job body. Returns :ok/:error tuples for retry semantics;
  # unexpected crashes retry via the worker's max_attempts.
  def provision(agent_id) do
    with {:ok, cfg} <- provisioner_config(),
         %{state: state} = row <- fetch_bot(agent_id) || open_pending!(agent_id),
         true <- state in ["pending", "stale"] do
      do_provision(cfg, row)
    else
      nil -> {:error, :no_row}
      false -> {:ok, :noop}
      {:error, _} = error -> error
    end
  end

  def retire_job(agent_id) do
    case fetch_bot(agent_id) do
      %{state: "retired"} = row -> retire_remote(row)
      _ -> :ok
    end
  end

  defp do_provision(cfg, row) do
    username = unique_username(row.agent_id)

    with {:ok, user_id} <- ensure_bot_user(cfg, %{mm_user_id: row.mm_user_id, display: row.agent_id}, username),
         :ok <- join_team(cfg, user_id),
         :ok <- join_channels(cfg, user_id),
         {:ok, token} <- Transport.create_bot_token(cfg, user_id) do
      Operations.update(
        row,
        :mark_active,
        Map.merge(
          %{mm_user_id: user_id, mm_username: username, display_name: row.agent_id, token: token, state: "active", last_error: nil},
          touched()
        ),
        @actor
      )

      {:ok, :active}
    else
      {:error, reason} ->
        Operations.update(row, :mark_stale, Map.merge(%{state: "stale", last_error: "provision:#{inspect(reason)}"}, touched()), @actor)
        {:error, reason}

      _ ->
        Operations.update(row, :mark_stale, Map.merge(%{state: "stale", last_error: "provision:unconfirmed"}, touched()), @actor)
        {:error, :unconfirmed}
    end
  rescue
    error ->
      try_stale(row, error)
      {:error, :crashed}
  end

  # Reuse the existing bot user when the row already has one (stale
  # token, reactivation): only the token is re-issued. A row that never
  # provisioned creates exactly one bot.
  defp ensure_bot_user(cfg, %{mm_user_id: "pending:" <> _, display: display}, username) do
    with {:ok, bot} <- Transport.create_bot(cfg, username, display),
         %{"user_id" => user_id} <- bot do
      {:ok, user_id}
    else
      _ -> {:error, :unconfirmed}
    end
  end

  defp ensure_bot_user(cfg, %{mm_user_id: user_id}, _username) do
    case Transport.set_bot_active(cfg, user_id, true) do
      :ok -> {:ok, user_id}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unconfirmed}
    end
  end

  defp try_stale(row, error) do
    Operations.update(row, :mark_stale, Map.merge(%{state: "stale", last_error: "provision:#{Exception.message(error) |> String.slice(0, 120)}"}, touched()), @actor)
  rescue
    _ -> :ok
  end

  defp join_team(cfg, user_id) do
    case team_id() do
      nil -> :ok
      "" -> :ok
      team -> Transport.add_team_member(cfg, team, user_id)
    end
  end

  defp join_channels(cfg, user_id) do
    bot_channels()
    |> Enum.reduce(:ok, fn channel_id, acc ->
      case {acc, Transport.add_channel_member(cfg, channel_id, user_id)} do
        {:ok, :ok} -> :ok
        {_, {:error, reason}} -> {:error, reason}
        {error, _} -> error
      end
    end)
  end

  defp retire_remote(%{mm_user_id: "pending:" <> _}), do: :ok
  defp retire_remote(%{mm_user_id: nil}), do: :ok
  defp retire_remote(%{mm_user_id: ""}), do: :ok

  defp retire_remote(row) do
    case provisioner_config() do
      {:ok, cfg} ->
        with :ok <- Transport.set_bot_active(cfg, row.mm_user_id, false),
             :ok <- revoke_all(cfg, row.mm_user_id) do
          :ok
        else
          _ -> {:error, :unconfirmed}
        end

      _ ->
        {:error, :unconfirmed}
    end
  rescue
    _ -> {:error, :unconfirmed}
  end

  defp revoke_all(cfg, user_id) do
    case Transport.list_user_tokens(cfg, user_id) do
      {:ok, tokens} ->
        results =
          Enum.map(tokens, fn
            %{"id" => token_id} -> Transport.revoke_user_token(cfg, user_id, token_id)
            _ -> :ok
          end)

        if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :unconfirmed}

      _ ->
        {:error, :unconfirmed}
    end
  end

  defp mark_stale(row, reason) do
    Operations.update(row, :mark_stale, Map.merge(%{state: "stale", last_error: reason}, touched()), @actor)
  rescue
    _ -> :ok
  end

  defp created_stamps do
    now = Operations.now()
    %{created_at: now, updated_at: now}
  end

  defp touched do
    %{updated_at: Operations.now()}
  end

  defp error(_), do: {:error, :no_bot}

  defp open_pending(agent_id) do
    Operations.create(
      AgentBot,
      :open,
      Map.merge(
        %{id: Ash.UUID.generate(), agent_id: agent_id, mm_user_id: "pending:#{agent_id}", mm_username: short_name(agent_id), display_name: agent_id, state: "pending"},
        created_stamps()
      ),
      @actor
    )
  rescue
    _ -> :ok
  end

  defp open_pending!(agent_id) do
    case fetch_bot(agent_id) do
      nil ->
        open_pending(agent_id)
        fetch_bot(agent_id)

      row ->
        row
    end
  end

  defp fetch_bot(agent_id) do
    AgentBot
    |> Ash.Query.filter(agent_id == ^agent_id)
    |> Ash.read_one!()
  rescue
    _ -> nil
  end

  defp fetch_username(username) do
    AgentBot
    |> Ash.Query.filter(mm_username == ^username)
    |> Ash.read_one!()
  rescue
    _ -> nil
  end

  defp load_token(row) do
    case Ash.load!(row, :token) do
      %{token: token} -> {:ok, token}
      _ -> {:error, :unreadable}
    end
  rescue
    _ -> {:error, :unreadable}
  end

  defp enqueue_bot_job(action, agent_id) do
    %{"action" => action, "agent_id" => agent_id}
    |> Agentboard.Mattermost.BotProvisioner.new()
    |> Oban.insert()
    |> case do
      {:ok, _} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # Server-held provisioner credential, Secret refs only: file-backed
  # token preferred, environment fallback. Never logged or returned.
  defp provisioner_config do
    token =
      case Application.get_env(:agentboard, :mattermost_provisioner_token_file) do
        nil -> Application.get_env(:agentboard, :mattermost_provisioner_token)
        file when is_binary(file) -> read_token_file(file)
      end

    base_url = Agentboard.Mattermost.Bridge.base_url()

    cond do
      !is_binary(token) or String.trim(token) == "" -> {:error, :unavailable}
      !is_binary(base_url) or base_url == "" -> {:error, :unavailable}
      true -> {:ok, %{token: String.trim(token), base_url: base_url}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp read_token_file(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp provisionable? do
    match?({:ok, _}, provisioner_config()) and cloak_ready?()
  end

  defp cloak_ready? do
    key_source =
      case System.get_env("AGENTBOARD_MATTERMOST_CLOAK_KEY_FILE") do
        nil -> System.get_env("AGENTBOARD_MATTERMOST_CLOAK_KEY")
        "" -> System.get_env("AGENTBOARD_MATTERMOST_CLOAK_KEY")
        file when is_binary(file) ->
          case File.read(file) do
            {:ok, contents} -> contents
            _ -> nil
          end
      end

    is_binary(key_source) and key_source != "" and key_bytes?(String.trim(key_source))
  end

  defp key_bytes?(contents) do
    case Base.decode64(contents) do
      {:ok, key} when byte_size(key) == 32 -> true
      _ -> byte_size(contents) == 32
    end
  end

  defp team_id do
    Application.get_env(:agentboard, :mattermost_team_id)
  end

  defp bot_channels do
    configured =
      Application.get_env(:agentboard, :mattermost_agent_bot_channel_ids, "")
      |> to_string()
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    board = Application.get_env(:agentboard, :mattermost_board_channel_id)

    (configured ++ List.wrap(board))
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
