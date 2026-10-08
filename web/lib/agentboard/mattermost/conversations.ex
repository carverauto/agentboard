defmodule Agentboard.Mattermost.Conversations do
  @moduledoc """
  Agent chat. An agent message posts through that agent's own bot when
  its elastic bot row is active, otherwise through the ONE shared
  `agentboard` bot; agents never hold Mattermost credentials and the
  CLI calls the Agentboard API. Attribution derives from the
  Agentboard-authenticated agent id plus structured post props, never from
  the display name.
  """
  alias Agentboard.Board.Operations
  alias Agentboard.Mattermost.{ConversationCoverage, Delivery, ElasticBots, Transport}
  require Ash.Query

  @actor %{"agent" => "mattermost-conversations", "model" => "system", "harness" => "ash"}

  @post_props ~w(agent_id task_id kind msg_id agentboard_retry_key)
  @kinds ~w(status decision handoff ask-user note)
  @read_per_page 60
  @read_max_pages 5

  # Server-side send on behalf of an Agentboard-authenticated agent. The
  # caller is verified against the registered agent roster first; the
  # shared bot token never leaves the server.
  def send_as(caller, params) when is_map(params) do
    with {:ok, agent_id} <- registered_agent(caller),
         {:ok, channel_id, body, task_id, kind, root_id, retry_key, icon_url} <- send_params(params),
         {:ok, channel_id} <- check_channel_scope(channel_id),
         {:ok, cfg} <- Delivery.bot_config() do
      msg_id = Ash.UUID.generate()
      header = "[#{agent_id} · #{task_id}]"
      message = header <> "\n" <> body

      props = %{
        "agent_id" => agent_id,
        "task_id" => task_id,
        "kind" => kind,
        "msg_id" => msg_id,
        "agentboard_retry_key" => retry_key
      }

      case adopt_retry(cfg, channel_id, retry_key, agent_id) do
        {:ok, nil} ->
          with {:ok, sent} <- post_as(cfg, agent_id, channel_id, message, props, root_id, icon_url, msg_id) do
            # Best-effort send receipt: the post is the primary result and
            # later reads record coverage anyway, so a receipt-write failure
            # must not misreport the send itself.
            _ = record_coverage(agent_id, channel_id, sent["post"]["id"], 0, false, "send_only")
            {:ok, sent}
          end

        {:ok, post} ->
          {:ok, %{"duplicate" => true, "post" => post, "msg_id" => get_in(post, ["props", "msg_id"])}}

        {:error, _code, _message} = error ->
          error
      end
    end
  end

  # Pluggable posting seam: the agent's own bot when active, the shared
  # bot otherwise. Props and header are identical either way; override
  # fields follow the cached server observation. A revoked bot token
  # re-provisions in the background and the same send falls back once.
  def post_as(cfg, agent_id, channel_id, message, props, root_id \\ nil, icon_url \\ nil, msg_id \\ nil) do
    {send_cfg, via_bot} = send_config(cfg, agent_id)
    do_post_as(send_cfg, via_bot, cfg, agent_id, channel_id, message, props, root_id, icon_url, msg_id)
  end

  defp do_post_as(send_cfg, via_bot, shared_cfg, agent_id, channel_id, message, props, root_id, icon_url, msg_id) do
    {username_opt, icon_opt} = override_opts(agent_id, icon_url)
    opts = [root_id: root_id, override_username: username_opt, override_icon_url: icon_opt]

    case Transport.post_agent(send_cfg, channel_id, message, props, opts) do
      {:ok, 201, %{"id" => _} = post} ->
        observe_overrides(post, username_opt, icon_opt)
        {:ok, %{"duplicate" => false, "post" => post, "msg_id" => msg_id}}

      {:ok, 404, _} ->
        {:error, "not_found", "channel not found"}

      {:ok, 400, _} ->
        {:error, "invalid_input", "Mattermost rejected the post"}

      {:ok, status, _} when status in [401, 403] and via_bot ->
        ElasticBots.note_revoked(agent_id)

        do_post_as(shared_cfg, false, shared_cfg, agent_id, channel_id, message, props, root_id, icon_url, msg_id)

      {:ok, _status, _} ->
        {:error, "unavailable", "Mattermost did not acknowledge the post"}

      {:error, :unauthorized} ->
        {:error, "unavailable", "bridge unauthorized; rotate the bridge token"}

      {:error, _} ->
        {:error, "unavailable", "Mattermost post failed"}
    end
  end

  defp send_config(cfg, agent_id) do
    case ElasticBots.token_for(agent_id) do
      {:ok, token} -> {%{cfg | token: token}, true}
      _ -> {cfg, false}
    end
  end

  # Server-side read with own-echo suppression by props.agent_id (every
  # post shares the bot user, so MM user id suppression is meaningless).
  # Coverage is recorded as part of the read; incomplete catch-up stays
  # explicit with a reason.
  def reads(caller, channel_id, since, limit) do
    with {:ok, agent_id} <- registered_agent(caller),
         {:ok, channel_id} <- channel_param(channel_id),
         {:ok, channel_id} <- check_channel_scope(channel_id),
         {:ok, limit} <- read_limit(limit),
         {:ok, cfg} <- Delivery.bot_config(),
         {:ok, order, posts} <- channel_history(cfg, channel_id, limit) do
      since = normalize_since(since)
      {selected, newest, found_since} = select_since(order, posts, agent_id, since)
      {caught_up, reason} = catch_up_state(since, found_since, nil)

      if is_nil(newest) do
        if since in [nil, ""] do
          {:ok, %{"channel_id" => channel_id, "posts" => [], "caught_up" => false, "incomplete_reason" => "no_posts"}}
        else
          if found_since do
            case record_coverage(agent_id, channel_id, since, true, nil) do
              {:ok, _} ->
                {:ok, %{"channel_id" => channel_id, "posts" => [], "caught_up" => caught_up, "incomplete_reason" => reason}}

              {:error, _code, _message} = error ->
                error
            end
          else
            {:ok, %{"channel_id" => channel_id, "posts" => [], "caught_up" => caught_up, "incomplete_reason" => reason}}
          end
        end
      else
        {cover_id, cover_version} = coverage_target(agent_id, channel_id, order, posts, newest, since, found_since)
        case record_coverage(agent_id, channel_id, cover_id, cover_version, caught_up, reason) do
          {:ok, _} ->
            {:ok, %{"channel_id" => channel_id, "posts" => selected, "caught_up" => caught_up, "incomplete_reason" => reason}}

          {:error, _code, _message} = error ->
            error
        end
      end
    end
  end

  # Explicit coverage receipt (kept for compatibility with headless
  # catch-up loops that observe without the reads path). The caller must
  # be the registered agent it reports for; the controller enforces the
  # path/header match before this runs.
  def report_coverage(caller, channel_id, last_post_id, last_version, opts \\ []) do
    with {:ok, agent_id} <- registered_agent(caller),
         {:ok, channel_id} <- channel_param(channel_id),
         {:ok, last_post_id} <- present(last_post_id, "last_post_id is required"),
         {:ok, last_version} <- non_negative(last_version),
         {:ok, reason} <- optional_text(opts[:incomplete_reason], 512) do
      caught_up = Keyword.get(opts, :caught_up, false) == true
      record_coverage(agent_id, channel_id, last_post_id, last_version, caught_up, reason)
    end
  end

  def coverage(agent_id, channel_id) do
    case fetch_coverage(agent_id, channel_id) do
      nil -> {:error, "not_found", "No coverage reported"}
      row -> {:ok, Operations.public(row)}
    end
  end

  # Read-only diagnostics: cached override observations, never secrets.
  # Each field carries its own observed_at/stale/source; a stale field
  # is re-observed by the next send that actually carries it.
  def diagnostics(caller) do
    with {:ok, agent_id} <- registered_agent(caller) do
      support = override_support()

      {:ok,
       %{
         "overrides" => %{
           "username" => support[:username],
           "username_observed_at" => support[:username_observed_at],
           "username_stale" => not override_fresh?(support[:username_observed_at]),
           "username_source" => if(is_nil(support[:username_observed_at]), do: "unobserved", else: "observed"),
           "icon" => support[:icon],
           "icon_observed_at" => support[:icon_observed_at],
           "icon_stale" => not override_fresh?(support[:icon_observed_at]),
           "icon_source" => if(is_nil(support[:icon_observed_at]), do: "unobserved", else: "observed")
         },
         "bot" => ElasticBots.bot_info(agent_id)
       }}
    end
  end

  # Override support is observed, never configured: the stored post in a
  # 201 response keeps the override fields only when the server applied
  # them (a server with the flags off strips them). Observations are
  # cached per field with separate timestamps; an expired field gates as
  # unknown, so the next send carrying that field re-observes it while a
  # field the send omits keeps its own timestamp. Only fields actually
  # sent update the cache. Nothing here reads or writes server configuration.
  @override_ttl_s 3_600

  defp override_opts(agent_id, icon_url) do
    username = if override_gated(:username) == false, do: nil, else: agent_id

    icon =
      if override_gated(:icon) == false or is_nil(icon_url), do: nil, else: icon_url

    {username, icon}
  end

  defp override_gated(field) do
    support = override_support()

    observed_at =
      case field do
        :username -> support[:username_observed_at]
        :icon -> support[:icon_observed_at]
      end

    if override_fresh?(observed_at), do: support[field], else: nil
  end

  defp observe_overrides(_post, nil, nil), do: :ok

  defp observe_overrides(post, sent_username, sent_icon) do
    current = override_support()
    now = System.system_time(:second)

    observed = %{
      username: observe_field(post, "override_username", sent_username, current[:username]),
      username_observed_at: if(is_nil(sent_username), do: current[:username_observed_at], else: now),
      icon: observe_field(post, "override_icon_url", sent_icon, current[:icon]),
      icon_observed_at: if(is_nil(sent_icon), do: current[:icon_observed_at], else: now)
    }

    Application.put_env(:agentboard, :mattermost_override_support, observed)
    :ok
  end

  defp observe_field(_post, _field, nil, current), do: current

  defp observe_field(post, field, sent, _current) do
    stored = post[field] || get_in(post, ["props", field])
    stored == sent
  end

  defp override_support do
    case Application.get_env(:agentboard, :mattermost_override_support) do
      %{username: _, username_observed_at: _, icon: _, icon_observed_at: _} = support -> support
      %{username: username, icon: icon, observed_at: observed_at} ->
        %{username: username, username_observed_at: observed_at, icon: icon, icon_observed_at: observed_at}
      _ -> %{username: nil, username_observed_at: nil, icon: nil, icon_observed_at: nil}
    end
  end

  defp override_fresh?(nil), do: false

  defp override_fresh?(observed_at) do
    System.system_time(:second) - observed_at < override_ttl_s()
  end

  defp override_ttl_s do
    case Application.get_env(:agentboard, :mattermost_override_ttl_s, @override_ttl_s) do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds
      _ -> @override_ttl_s
    end
  end

  defp registered_agent(caller) do
    agent_id = caller["agent"]

    case Operations.registered_agent(agent_id, caller["harness"]) do
      {:ok, _} -> {:ok, agent_id}
      {:error, _, _} -> {:error, "invalid_context", "Register a matching agent identity first"}
    end
  end



  defp send_params(params) do
    with {:ok, channel_id} <- present(params["channel_id"], "channel_id is required"),
         {:ok, channel_id} <- capped(channel_id, 128, "channel_id exceeds 128 characters"),
         {:ok, channel_id} <- channel_shape(channel_id),
         {:ok, body} <- present(params["body"], "body is required"),
         {:ok, body} <- capped(body, 16_383, "body exceeds 16383 characters"),
         {:ok, kind} <- send_kind(params["kind"]),
         {:ok, retry_key} <- optional_text(params["retry_key"], 128),
         {:ok, task_id} <- send_task_id(params["task_id"]),
         {:ok, root_id} <- optional_text(params["root_id"], 128),
         {:ok, icon_url} <- optional_text(params["icon_url"], 512) do
      {:ok, channel_id, body, task_id || "general", kind, root_id, retry_key, icon_url}
    end
  end

  defp send_task_id(value) do
    with {:ok, task_id} <- optional_text(value, 128),
         :ok <- task_id_shape(task_id) do
      {:ok, task_id}
    end
  end

  defp task_id_shape(nil), do: :ok

  defp task_id_shape(task_id) do
    if String.contains?(task_id, ["\n", "\r", "[", "]"]) do
      {:error, "invalid_input", "task_id must not contain newlines or brackets"}
    else
      :ok
    end
  end

  defp normalize_since(nil), do: nil

  defp normalize_since(since) when is_binary(since) do
    case String.trim(since) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_since(since), do: since

  defp coverage_target(_agent_id, _channel_id, _order, _posts, newest, since, found_since)
       when is_nil(since) or found_since == true do
    {newest, 0}
  end

  defp coverage_target(agent_id, channel_id, order, posts, newest, _since, _found_since) do
    case fetch_coverage(agent_id, channel_id) do
      %{last_post_id: last_id, last_version: version} when is_binary(last_id) ->
        {last_id, version || 0}

      _ ->
        {window_floor(order, posts) || newest, 0}
    end
  end

  defp window_floor(order, posts) do
    Enum.find_value(Enum.reverse(order), fn id ->
      case posts[id] do
        %{"id" => pid} when is_binary(pid) -> pid
        _ -> nil
      end
    end)
  end

  defp send_kind(nil), do: {:ok, "note"}
  defp send_kind(kind) when is_binary(kind) do
    trimmed = String.trim(kind)

    cond do
      trimmed == "" -> {:ok, "note"}
      trimmed in @kinds -> {:ok, trimmed}
      true -> {:error, "invalid_input", "kind must be one of #{Enum.join(@kinds, ", ")}"}
    end
  end
  defp send_kind(_), do: {:error, "invalid_input", "kind must be one of #{Enum.join(@kinds, ", ")}"}

  defp present(nil, message), do: {:error, "invalid_input", message}
  defp present("", message), do: {:error, "invalid_input", message}

  defp present(value, _message) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "invalid_input", "value must not be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp present(_, message), do: {:error, "invalid_input", message}

  defp optional_text(nil, _max), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > max -> {:error, "invalid_input", "value exceeds #{max} characters"}
      true -> {:ok, trimmed}
    end
  end

  defp optional_text(_, _), do: {:error, "invalid_input", "value must be text"}

  defp capped(value, max, message) when is_binary(value) do
    if String.length(value) > max, do: {:error, "invalid_input", message}, else: {:ok, value}
  end

  defp channel_param(value) do
    with {:ok, channel_id} <- present(value, "channel_id is required"),
         {:ok, channel_id} <- capped(channel_id, 128, "channel_id exceeds 128 characters"),
         {:ok, channel_id} <- channel_shape(channel_id) do
      {:ok, channel_id}
    end
  end

  defp channel_shape(channel_id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, channel_id),
      do: {:ok, channel_id},
      else: {:error, "invalid_input", "channel_id uses an unexpected shape"}
  end

  defp check_channel_scope(channel_id) do
    case channel_allowlist() do
      :any -> {:ok, channel_id}
      listed when is_list(listed) ->
        if channel_id in listed,
          do: {:ok, channel_id},
          else: {:error, "invalid_context", "channel is not allowlisted for agent chat"}
    end
  end

  defp channel_allowlist do
    configured =
      case Application.get_env(:agentboard, :mattermost_channel_allowlist) do
        nil -> System.get_env("AGENTBOARD_MATTERMOST_CHANNEL_ALLOWLIST") || ""
        "" -> ""
        value when is_binary(value) -> value
        values when is_list(values) -> Enum.join(values, ",")
      end

    listed =
      configured |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case listed do
      [] -> :any
      _ -> listed
    end
  end

  defp read_limit(nil), do: {:ok, 50}
  defp read_limit(""), do: {:ok, 50}

  defp read_limit(limit) when is_integer(limit) and limit >= 1 and limit <= 200, do: {:ok, limit}

  defp read_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {n, ""} when n >= 1 and n <= 200 -> {:ok, n}
      _ -> {:error, "invalid_input", "limit must be between 1 and 200"}
    end
  end

  defp read_limit(_), do: {:error, "invalid_input", "limit must be between 1 and 200"}

  defp non_negative(nil), do: {:ok, 0}
  defp non_negative(""), do: {:ok, 0}
  defp non_negative(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp non_negative(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {v, ""} when v >= 0 -> {:ok, v}
      _ -> {:error, "invalid_input", "last_version must be a non-negative integer"}
    end
  end

  defp non_negative(_), do: {:error, "invalid_input", "last_version must be a non-negative integer"}

  defp adopt_retry(_cfg, _channel_id, nil, _agent_id), do: {:ok, nil}

  defp adopt_retry(cfg, channel_id, retry_key, agent_id) do
    case Transport.find_by_retry_key(cfg, channel_id, retry_key, agent_id) do
      {:ok, nil} -> {:ok, nil}
      {:ok, post} -> {:ok, post}
      {:error, :unauthorized} -> {:error, "unavailable", "bridge unauthorized; rotate the bridge token"}
      {:error, :not_found} -> {:error, "not_found", "channel not found"}
      {:error, _} -> {:error, "unavailable", "retry-key lookup failed; send aborted instead of risking a duplicate"}
    end
  end

  defp channel_history(cfg, channel_id, limit) do
    pages = div(limit + @read_per_page - 1, @read_per_page)
    pages = min(pages, @read_max_pages)

    Enum.reduce_while(1..pages//1, {:ok, [], %{}}, fn page, {:ok, order_acc, posts_acc} ->
      case Transport.channel_page(cfg, channel_id, page - 1, @read_per_page) do
        {:ok, 200, %{"order" => order, "posts" => posts}} ->
          merged = Map.merge(posts_acc, posts || %{})
          needed = Enum.uniq(order_acc ++ (order || []))

          if length(needed) >= limit or length(order || []) < @read_per_page,
            do: {:halt, {:ok, Enum.take(needed, limit), merged}},
            else: {:cont, {:ok, needed, merged}}

        {:ok, status, _} when status in [401, 403] ->
          {:halt, {:error, "unavailable", "bridge unauthorized; rotate the bridge token"}}

        {:ok, 404, _} ->
          {:halt, {:error, "not_found", "channel not found"}}

        {:ok, 400, _} ->
          {:halt, {:error, "invalid_input", "channel history rejected"}}

        _ ->
          {:halt, {:error, "unavailable", "channel history unavailable"}}
      end
    end)
  end

  defp select_since(order, posts, agent_id, since) do
    Enum.reduce_while(order, {[], nil, since in [nil, ""]}, fn id, {acc, newest, found} ->
      cond do
        since not in [nil, ""] and id == since -> {:halt, {acc, newest, true}}
        true ->
          case posts[id] do
            %{"id" => pid} = post when is_binary(pid) ->
              newest = newest || pid
              if get_in(post, ["props", "agent_id"]) == agent_id, do: {:cont, {acc, newest, found}}, else: {:cont, {[slim(post) | acc], newest, found}}
            _ -> {:cont, {acc, newest, found}}
          end
      end
    end)
  end

  defp slim(post) do
    props = post["props"] || %{}
    %{
      "id" => post["id"],
      "channel_id" => post["channel_id"],
      # Real Mattermost authorship is preserved: shared-bot posts carry
      # props.agent_id attribution while human posts keep their user id.
      "user_id" => post["user_id"],
      "root_id" => post["root_id"],
      "create_at" => post["create_at"],
      "update_at" => post["update_at"],
      "message" => post["message"],
      "props" => Map.take(props, @post_props)
    }
  end

  defp catch_up_state(since, found_since, _reason) when since in [nil, ""] do
    {false, "bounded_snapshot"}
  end

  defp catch_up_state(_since, true, _reason), do: {true, nil}
  defp catch_up_state(_since, false, _reason), do: {false, "cursor_not_found"}

  defp record_coverage(agent_id, channel_id, last_post_id, caught_up, reason) when is_binary(last_post_id) do
    record_coverage(agent_id, channel_id, last_post_id, 0, caught_up, reason)
  end

  defp record_coverage(agent_id, channel_id, last_post_id, last_version, caught_up, reason) do
    case do_record_coverage(agent_id, channel_id, last_post_id, last_version, caught_up, reason) do
      {:error, "conflict", _} ->
        do_record_coverage(agent_id, channel_id, last_post_id, last_version, caught_up, reason)

      result ->
        result
    end
  end

  defp do_record_coverage(agent_id, channel_id, last_post_id, last_version, caught_up, reason) do
    Operations.transaction(fn ->
      stamp = Operations.now()

      coverage =
        case fetch_coverage(agent_id, channel_id) do
          nil ->
            Operations.create(
              ConversationCoverage,
              :open,
              %{id: Ash.UUID.generate(), agent_id: agent_id, channel_id: channel_id, created_at: stamp, updated_at: stamp},
              @actor
            )

          row ->
            # Re-check nothing here: coverage rows are per-agent-channel
            # progress markers, and the caller proved a registered identity
            # before this transaction opened.
            row
        end

      Operations.update(
        coverage,
        :report,
        %{
          last_post_id: last_post_id,
          last_version: last_version,
          caught_up: caught_up,
          incomplete_reason: if(caught_up, do: nil, else: reason || "catch_up_incomplete"),
          checked_at: stamp,
          updated_at: stamp
        },
        @actor
      )
      |> Operations.public()
    end)
  end

  defp fetch_coverage(agent_id, channel_id) do
    ConversationCoverage
    |> Ash.Query.filter(agent_id == ^agent_id and channel_id == ^channel_id)
    |> Ash.read_one!()
  end

  def actor, do: @actor
end
