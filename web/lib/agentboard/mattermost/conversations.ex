defmodule Agentboard.Mattermost.Conversations do
  @moduledoc """
  Phase 1 shared-bot agent chat. Every agent message posts through the ONE
  shared `agentboard` bot; agents never hold Mattermost credentials and the
  CLI calls the Agentboard API. Attribution derives from the
  Agentboard-authenticated agent id plus structured post props, never from
  the display name. The posting seam (`post_as/2`) stays pluggable so phase
  2 per-agent bots swap in transparently.
  """
  alias Agentboard.Board.Operations
  alias Agentboard.Mattermost.{ConversationCoverage, Delivery, Transport}
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
          {:ok, %{"duplicate" => true, "post" => post}}

        {:error, _code, _message} = error ->
          error
      end
    end
  end

  # Pluggable posting seam: shared bot now, per-agent bot later. Override
  # fields render only when farm01 enables the Mattermost override
  # settings; header plus props carry identity either way.
  def post_as(cfg, agent_id, channel_id, message, props, root_id \\ nil, icon_url \\ nil, msg_id \\ nil) do
    opts = [root_id: root_id, override_username: agent_id, override_icon_url: icon_url]

    case Transport.post_agent(cfg, channel_id, message, props, opts) do
      {:ok, 201, %{"id" => _} = post} ->
        {:ok, %{"duplicate" => false, "post" => post, "msg_id" => msg_id}}

      {:ok, 404, _} ->
        {:error, "not_found", "channel not found"}

      {:ok, _status, _} ->
        {:error, "unavailable", "Mattermost did not acknowledge the post"}

      {:error, :unauthorized} ->
        {:error, "unavailable", "bridge unauthorized; rotate the bridge token"}

      {:error, _} ->
        {:error, "unavailable", "Mattermost post failed"}
    end
  end

  # Server-side read with own-echo suppression by props.agent_id (every
  # post shares the bot user, so MM user id suppression is meaningless).
  # Coverage is recorded as part of the read; incomplete catch-up stays
  # explicit with a reason.
  def reads(caller, channel_id, since, limit) do
    with {:ok, agent_id} <- registered_agent(caller),
         {:ok, channel_id} <- present(channel_id, "channel_id is required"),
         {:ok, limit} <- read_limit(limit),
         {:ok, cfg} <- Delivery.bot_config(),
         {:ok, order, posts} <- channel_history(cfg, channel_id, limit) do
      {selected, newest, found_since} = select_since(order, posts, agent_id, since)
      {caught_up, reason} = catch_up_state(since, found_since, nil)

      if is_nil(newest) do
        {:ok, %{"channel_id" => channel_id, "posts" => [], "caught_up" => false, "incomplete_reason" => "no_posts"}}
      else
        case record_coverage(agent_id, channel_id, newest, caught_up, reason) do
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
         {:ok, channel_id} <- present(channel_id, "channel_id is required"),
         {:ok, last_post_id} <- present(last_post_id, "last_post_id is required"),
         {:ok, last_version} <- non_negative(last_version) do
      caught_up = Keyword.get(opts, :caught_up, false) == true
      reason = opts[:incomplete_reason]
      record_coverage(agent_id, channel_id, last_post_id, last_version, caught_up, reason)
    end
  end

  def coverage(agent_id, channel_id) do
    case fetch_coverage(agent_id, channel_id) do
      nil -> {:error, "not_found", "No coverage reported"}
      row -> {:ok, Operations.public(row)}
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
         {:ok, body} <- present(params["body"], "body is required"),
         {:ok, kind} <- send_kind(params["kind"]),
         {:ok, retry_key} <- optional_text(params["retry_key"], 128),
         {:ok, task_id} <- optional_text(params["task_id"], 128),
         {:ok, root_id} <- optional_text(params["root_id"], 128),
         {:ok, icon_url} <- optional_text(params["icon_url"], 512) do
      {:ok, channel_id, body, task_id || "general", kind, root_id, retry_key, icon_url}
    end
  end

  defp send_kind(nil), do: {:ok, "note"}
  defp send_kind(kind) when kind in @kinds, do: {:ok, kind}
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
  defp non_negative(n) when is_integer(n) and n >= 0, do: {:ok, n}
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
          needed = order_acc ++ (order || [])

          if length(needed) >= limit or length(order || []) < @read_per_page,
            do: {:halt, {:ok, Enum.take(needed, limit), merged}},
            else: {:cont, {:ok, needed, merged}}

        {:ok, status, _} when status in [401, 403] ->
          {:halt, {:error, "unavailable", "bridge unauthorized; rotate the bridge token"}}

        {:ok, 404, _} ->
          {:halt, {:error, "not_found", "channel not found"}}

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
