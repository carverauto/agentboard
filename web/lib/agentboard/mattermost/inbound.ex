defmodule Agentboard.Mattermost.Inbound do
  @moduledoc "Shared-bot inbound routing and overlapping reconciliation. Chat remains evidence, never command authority."
  alias Agentboard.Mattermost.{Delivery, InboundHTTP, InboundStore}
  alias Agentboard.{Input, Repo}
  @historical_gap "historical_deletions_unprovable"

  def enabled?, do: Application.get_env(:agentboard, :mattermost_inbound_enabled, false)

  def config do
    with {:ok, cfg} <- base_config(), do: verify_bot(cfg)
  end

  def base_config do
    repo = Application.get_env(:agentboard, :mattermost_inbound_repo)
    history_start = Application.get_env(:agentboard, :mattermost_inbound_history_start_ms)
    with true <- is_binary(repo) and Regex.match?(~r/^[a-z0-9_.-]+\/[a-z0-9_.-]+$/, repo),
         true <- is_nil(history_start) or (is_integer(history_start) and history_start >= 0),
         {:ok, cfg} <- Delivery.bot_config() do
      {:ok, Map.put(cfg, :repo, repo)}
    else
      _ -> {:error, :bot_identity_or_scope_unverified}
    end
  end

  def verify_bot(cfg) do
    with {:ok, %{"id" => bot, "roles" => roles, "is_bot" => true}} <- InboundHTTP.me(cfg),
         true <- InboundHTTP.segment?(bot) and is_binary(roles) and "system_admin" not in String.split(roles) do
      {:ok, Map.put(cfg, :bot_id, bot)}
    else
      {:error, {:rate_limited, seconds}} -> {:error, {:rate_limited, seconds}}
      _ -> {:error, :bot_identity_or_scope_unverified}
    end
  end

  def channels(cfg) do
    with {:ok, channels} when is_list(channels) <- InboundHTTP.channels(cfg),
         true <- length(channels) <= 1000,
         true <- Enum.all?(channels, fn c -> is_map(c) and InboundHTTP.segment?(c["id"]) end) do
      {:ok, channels |> Enum.map(& &1["id"]) |> Enum.filter(&allowed?/1) |> Enum.uniq()}
    else
      {:error, {:rate_limited, seconds}} -> {:error, {:rate_limited, seconds}}
      _ -> {:error, :channel_discovery_incomplete}
    end
  end

  def allowed?(channel) do
    entries = Application.get_env(:agentboard, :mattermost_channel_allowlist, "")
    entries = if is_binary(entries), do: String.split(entries, ",", trim: true) |> Enum.map(&String.trim/1), else: entries
    is_list(entries) and (entries == [] or channel in entries)
  end

  def observe(cfg, post) do
    with true <- valid_post?(post) and allowed?(post["channel_id"]),
         {:ok, root} <- root(cfg, post) do
      attribution = attribution(cfg, post)
      inherited = attribution(cfg, root)
      task = inherited[:task_id] || attribution[:task_id]
      with {:ok, scoped_task} <- task_scope(cfg, task) do
        recipients = mentions(post["message"] || "") ++ if(post["root_id"] not in [nil, ""] and inherited[:agent_id], do: [inherited.agent_id], else: [])
        # Edits/removals/deletions still notify recipients of an earlier version.
        %{rows: previous} = Repo.statement!("SELECT DISTINCT worker_id FROM mattermost_inbox WHERE source=$1 AND post_id=$2", [cfg.source, post["id"]])
        recipients = (recipients ++ Enum.map(previous, &hd/1)) |> Enum.uniq()
        recipients = if attribution[:agent_id] && attribution[:msg_id], do: Enum.reject(recipients, &(&1 == attribution.agent_id)), else: recipients
        recipients = if bridge_echo?(cfg, post), do: [], else: recipients
        recipients = enrolled(cfg, recipients, post)
        InboundStore.capture(cfg, post, recipients, Map.put(attribution, :task_id, scoped_task))
      else
        {:error, _} -> InboundStore.capture(cfg, post, [], %{})
      end
    else
      false -> {:error, :invalid_or_disallowed_post}
      error -> error
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :store_unavailable}
  end

  def valid_post?(post) when is_map(post) do
    Enum.all?(~w(id channel_id user_id), &InboundHTTP.segment?(post[&1])) and
      (post["root_id"] in [nil, ""] or InboundHTTP.segment?(post["root_id"])) and
      Enum.all?(~w(create_at update_at edit_at delete_at), fn key -> is_nil(post[key]) or (is_integer(post[key]) and post[key] >= 0) end) and
      is_binary(post["message"]) and byte_size(post["message"]) <= 65_536 and not String.contains?(post["message"], <<0>>) and
      (is_nil(post["props"]) or is_map(post["props"]))
  end
  def valid_post?(_), do: false

  defp root(cfg, post) do
    if post["root_id"] in [nil, ""] do
      {:ok, post}
    else
      with {:ok, root} <- InboundHTTP.post(cfg, post["root_id"]),
           true <- valid_post?(root) and root["channel_id"] == post["channel_id"] and (root["delete_at"] || 0) == 0 do
        {:ok, root}
      else
        {:error, {:rate_limited, _} = rate} -> {:error, rate}
        {:error, reason} when reason in [:transport_error, :timeout, :response_too_large, :unexpected_status] -> {:error, {:source_transport, reason}}
        _ -> {:error, :thread_root_unavailable}
      end
    end
  end

  defp attribution(cfg, post) do
    props = post["props"] || %{}
    if post["user_id"] == cfg.bot_id and Input.slug?(props["agent_id"]) and
         is_binary(props["msg_id"]) and byte_size(props["msg_id"]) in 1..128 and
         not String.contains?(props["msg_id"], <<0>>) do
      %{agent_id: props["agent_id"], msg_id: props["msg_id"], kind: if(props["kind"] in ~w(status decision handoff ask-user note), do: props["kind"], else: "note"), task_id: if(Input.slug?(props["task_id"]), do: props["task_id"])}
    else
      %{}
    end
  end
  defp bridge_echo?(cfg, post), do: post["user_id"] == cfg.bot_id and is_binary(get_in(post, ["props", "agentboard_event_marker"]))
  defp mentions(text), do: Regex.scan(~r/(?<![a-zA-Z0-9_.-])@([a-zA-Z0-9][a-zA-Z0-9_.-]{0,127})(?![a-zA-Z0-9_.-])/, text, capture: :all_but_first) |> List.flatten()

  defp task_scope(_cfg, task) when task in [nil, "general"], do: {:ok, nil}
  defp task_scope(cfg, task) do
    %{rows: rows} = Repo.statement!("SELECT repo FROM tasks WHERE id=$1", [task])
    case rows do
      [[repo]] when is_binary(repo) ->
        repo = if String.contains?(repo, "/"), do: String.downcase(repo), else: "carverauto/" <> String.downcase(repo)
        if repo == cfg.repo, do: {:ok, task}, else: {:error, :task_repo_outside_scope}
      _ -> {:error, :unknown_task_route}
    end
  end
  defp enrolled(_cfg, [], _post), do: []
  defp enrolled(cfg, recipients, post) do
    history_start = Application.get_env(:agentboard, :mattermost_inbound_history_start_ms)
    stamp = Enum.max(Enum.map(~w(create_at update_at edit_at delete_at), &(post[&1] || 0)))
    %{rows: rows} = Repo.statement!("""
    SELECT s.id FROM cooperation_subscriptions s JOIN agents a ON a.id=s.id
    WHERE NOT s.revoked AND $1=ANY(s.repos) AND s.id=ANY($2::text[])
    AND ($3::bigint IS NOT NULL AND $4::bigint >= $3 OR $3 IS NULL AND to_timestamp($4::double precision/1000)>=s.enrolled_at)
    """, [cfg.repo, recipients, history_start, stamp])
    Enum.map(rows, &hd/1)
  end

  def reconcile(cfg) do
    with {:ok, channels} <- channels(cfg) do
      %{rows: prior_channels} = Repo.statement!("SELECT channel_id FROM mattermost_channel_recovery WHERE source=$1", [cfg.source])
      Enum.each(prior_channels, fn [channel] ->
        if channel not in channels, do: InboundStore.coverage(cfg, channel, nil, false, "membership_or_allowlist_revoked")
      end)
      outcome =
        Enum.reduce_while(channels, [], fn channel, acc ->
          case scan_channel(cfg, channel) do
            {:error, :owner_expired} = error -> {:halt, error}
            {:error, :store_unavailable} = error -> {:halt, error}
            result -> {:cont, [result | acc]}
          end
        end)
      case outcome do
        {:error, :owner_expired} = error -> error
        {:error, :store_unavailable} = error -> error
        results ->
          case Enum.find(results, fn result -> match?({:gap, {:rate_limited, _}}, result) end) do
            {:gap, rate_limit} -> {:error, rate_limit}
            _ -> {:ok, channels, results}
          end
      end
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :store_unavailable}
  end

  defp scan_channel(cfg, channel) do
    with {:ok, :ok} <- InboundStore.coverage(cfg, channel, 0, false, "catch_up_in_progress"),
         {:ok, versions, scan_gaps, missing_gaps, capacity} <- stable_scan(cfg, channel, nil, 0) do
      if scan_gaps == [] and missing_gaps == [] and not capacity do
        case InboundStore.coverage(cfg, channel, 0, true, @historical_gap) do
          {:ok, :ok} -> {:ok, channel}
          {:error, :owner_expired} = error -> error
          {:error, :store_unavailable} = error -> error
        end
      else
        case InboundStore.coverage(cfg, channel, nil, false, hole_reason(scan_gaps, missing_gaps, capacity)) do
          {:ok, :ok} -> {:gap, :post_gap}
          {:error, :owner_expired} = error -> error
          {:error, :store_unavailable} = error -> error
        end
      end
    else
      {:error, :owner_expired} = error -> error
      {:error, :store_unavailable} = error -> error
      {:error, reason} ->
        case InboundStore.coverage(cfg, channel, nil, false, reason_text(reason)) do
          {:ok, :ok} -> {:gap, reason}
          {:error, :owner_expired} = error -> error
          {:error, :store_unavailable} = error -> error
        end
    end
  end

  defp stable_scan(_cfg, _channel, _prior, 3), do: {:error, :history_changed_during_scan}
  defp stable_scan(cfg, channel, prior, round) do
    with {:ok, versions, scan_gaps, scan_capacity} <- scan(cfg, channel, 0, %{}, []),
         {:ok, missing_gaps, missing_capacity} <- verify_missing(cfg, channel, versions) do
      gaps = {Enum.uniq(scan_gaps) |> Enum.take(8), Enum.uniq(missing_gaps) |> Enum.take(8)}
      capacity = scan_capacity or missing_capacity
      if versions == prior, do: {:ok, versions, elem(gaps, 0), elem(gaps, 1), capacity}, else: stable_scan(cfg, channel, versions, round + 1)
    else
      {:error, :owner_expired} = error -> error
      {:error, :store_unavailable} = error -> error
      {:error, _} = error -> error
    end
  end

  defp scan(cfg, channel, page, versions, gaps) do
    max_pages = Application.get_env(:agentboard, :mattermost_inbound_max_pages, 128)
    if page >= max_pages do
      {:error, :page_budget_exhausted}
    else
      with {:ok, %{"order" => order, "posts" => posts}} when is_list(order) and is_map(posts) <- InboundHTTP.page(cfg, channel, page),
           true <- length(order) <= 60 and map_size(posts) <= 60 and Enum.all?(order, &Map.has_key?(posts, &1)) do
        case capture_page(cfg, channel, order, posts, versions, gaps) do
          {:ok, versions, gaps} ->
            with {:ok, :ok} <- InboundStore.coverage(cfg, channel, page + 1, false, "catch_up_in_progress") do
              if length(order) < 60, do: {:ok, versions, gaps, false}, else: scan(cfg, channel, page + 1, versions, gaps)
            else
              {:error, :owner_expired} = error -> error
              {:error, :store_unavailable} = error -> error
              {:error, _} = error -> error
            end
          {:capacity, versions, gaps} -> {:ok, versions, gaps, true}
          {:error, :owner_expired} = error -> error
          {:error, :store_unavailable} = error -> error
          error -> error
        end
      else
        false -> {:error, :invalid_history_page}
        {:error, code, _} -> {:error, code}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_history_page}
      end
    end
  end

  defp capture_page(cfg, channel, order, posts, versions, gaps) do
    Enum.reduce_while(order, {:ok, versions, gaps}, fn id, {:ok, acc, gaps} ->
      post = posts[id]
      if valid_post?(post) and post["id"] == id and post["channel_id"] == channel do
        case observe(cfg, post) do
          {:ok, version} -> {:cont, {:ok, Map.put(acc, id, version), gaps}}
          {:error, :metadata_capacity_reached} -> {:halt, {:capacity, acc, gaps}}
          {:error, :owner_expired} = error -> {:halt, error}
          {:error, :store_unavailable} = error -> {:halt, error}
          {:error, reason} when reason in [:invalid_or_disallowed_post, :thread_root_unavailable] ->
            {:cont, {:ok, acc, add_gap(gaps, id)}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc, add_gap(gaps, id)}}
      end
    end)
  end

  defp add_gap(gaps, id) do
    id = if InboundHTTP.segment?(id), do: id, else: "invalid_id"
    (gaps ++ [id]) |> Enum.uniq() |> Enum.take(8)
  end

  defp hole_reason(scan_gaps, missing_gaps, capacity) do
    parts = []
    parts = if scan_gaps == [], do: parts, else: parts ++ ["uninspectable_post:" <> Enum.join(scan_gaps, ",")]
    parts = if missing_gaps == [], do: parts, else: parts ++ ["known_post_unavailable:" <> Enum.join(missing_gaps, ",")]
    parts = if capacity, do: parts ++ ["metadata_capacity_reached"], else: parts
    (if parts == [], do: @historical_gap, else: Enum.join(parts, ";")) |> String.slice(0, 256)
  end

  defp verify_missing(cfg, channel, versions) do
    with {:ok, known} <- InboundStore.known_posts(cfg, channel) do
      missing = Enum.reject(known, &Map.has_key?(versions, &1))
      verify_list(cfg, channel, versions, missing)
    end
  end

  defp verify_list(cfg, channel, versions, missing) do
    if length(missing) > 500 do
      {:error, :missing_post_budget_exhausted}
    else
      Enum.reduce_while(missing, {:ok, [], false}, fn id, {:ok, gaps, _capacity} ->
        case InboundHTTP.post(cfg, id) do
          {:ok, post} -> case observe(cfg, post) do
            {:ok, _} -> {:cont, {:ok, gaps, false}}
            {:error, :metadata_capacity_reached} -> {:halt, {:ok, gaps, true}}
            {:error, :owner_expired} = error -> {:halt, error}
            {:error, :store_unavailable} = error -> {:halt, error}
            {:error, reason} when reason in [:invalid_or_disallowed_post, :thread_root_unavailable] ->
              {:cont, {:ok, add_gap(gaps, id), false}}
            error -> {:halt, error}
          end
          {:error, reason} when reason in [:source_unavailable, :invalid_id] ->
            {:cont, {:ok, add_gap(gaps, id), false}}
          error -> {:halt, error}
        end
      end)
    end
  end

  def reason_text({:rate_limited, seconds}), do: "rate_limited:#{seconds}"
  def reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_text(reason) when is_binary(reason), do: reason
  def reason_text(_), do: "catch_up_incomplete"

  # Called only after capability-authenticated metadata reads, outside a transaction.
  def materialize(page) do
    cfg_result = if enabled?(), do: config(), else: {:error, :disabled}
    case cfg_result do
      {:ok, cfg} ->
        authorized_channels = case channels(cfg) do {:ok, channels} -> channels; _ -> [] end
        source = InboundStore.source(cfg)
        Map.update!(page, :items, fn items -> Enum.map(items, fn item ->
          result = if item.source == source and item.channel_id in authorized_channels, do: inspect_post(cfg, item), else: %{source_state: "source_unavailable"}
          Map.merge(item, result)
        end) end)
      _ -> Map.update!(page, :items, fn items -> Enum.map(items, &Map.put(&1, :source_state, "source_unavailable")) end)
    end
  end
  defp inspect_post(cfg, item) do
    with {:ok, post} <- InboundHTTP.post(cfg, item.post_id),
         true <- valid_post?(post) and post["channel_id"] == item.channel_id and InboundStore.version(post) == item.version,
         true <- (post["delete_at"] || 0) == 0 do
      %{source_state: "available", message: post["message"], source_url: cfg.base_url <> "/_redirect/pl/" <> item.post_id}
    else
      _ -> %{source_state: "source_unavailable"}
    end
  end
end
