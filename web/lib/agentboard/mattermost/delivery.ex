defmodule Agentboard.Mattermost.Delivery do
  @moduledoc """
  Send one claimed intent. All Mattermost HTTP happens outside transactions;
  every state commit is brief and fenced on the claim generation, so a stale
  or duplicate worker cannot overwrite a newer outcome.
  """
  alias Agentboard.Board.Operations
  alias Agentboard.Mattermost.{Bridge, Outbox, TaskThread, Transport}
  alias Agentboard.Repo

  @max_attempts 8
  @retry_delays %{rate_limited: 60, unreachable: 30, timeout: 30}

  def send_intent(id) when is_binary(id) do
    if Bridge.enabled?() do
      with {:ok, cfg} <- config(),
           %Outbox{state: "claimed"} = intent <- fetch_intent(id),
           true <- Bridge.thread_destination?(intent.destination, intent.task_id) do
        thread = Operations.fetch!(TaskThread, intent.task_id, "Task thread not found")
        deliver(cfg, intent, thread)
      else
        %Outbox{} -> {:ok, %{skipped: true}}
        false -> {:ok, %{skipped: true, reason: "recipient_route_unavailable"}}
        {:error, code, message} -> {:error, "#{code}: #{message}"}
        {:error, code} -> {:error, code}
      end
    else
      snooze()
    end
  end

  def send_intent(_), do: {:error, "invalid_input"}

  # Secret reference only: file-backed token preferred, environment fallback.
  # The value never enters logs, errors or job args.
  def config do
    token =
      case Application.get_env(:agentboard, :mattermost_bot_token_file) do
        nil -> Application.get_env(:agentboard, :mattermost_bot_token)
        file when is_binary(file) -> read_token_file(file)
      end

    base_url = Bridge.base_url()
    channel_id = Bridge.board_channel_id()

    cond do
      !is_binary(token) or String.trim(token) == "" -> {:error, "unauthorized"}
      !is_binary(base_url) or base_url == "" -> {:error, "unconfigured"}
      !is_binary(channel_id) or channel_id == "" -> {:error, "unconfigured"}
      true -> {:ok, %{token: String.trim(token), base_url: base_url, channel_id: channel_id}}
    end
  end

  defp read_token_file(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp fetch_intent(id) do
    case Ash.get!(Outbox, id, not_found_error?: false) do
      nil -> Operations.reject("not_found", "Outbox intent not found")
      intent -> intent
    end
  end

  defp deliver(cfg, intent, thread) do
    payload = intent.payload || %{}
    action = payload["action"] || "update"

    text =
      Bridge.message(
        action,
        intent.task_id,
        actor_of(payload),
        notice_note(payload),
        payload["status"]
      )

    if thread.state == "rooted" and is_binary(thread.root_post_id) do
      deliver_reply(cfg, intent, thread, text)
    else
      deliver_root(cfg, intent, thread, text)
    end
  end

  defp notice_note(%{"action" => "handoff", "to" => recipient} = payload)
       when is_binary(recipient) do
    "Handoff to #{recipient} (explicit claim required)\n" <> (payload["note"] || "")
  end

  defp notice_note(payload), do: payload["note"]

  defp actor_of(payload) do
    %{
      "agent" => payload["actor"] || "unknown",
      "model" => payload["model"] || "unknown",
      "harness" => payload["harness"] || "unknown"
    }
  end

  defp deliver_root(cfg, intent, thread, text) do
    case Transport.post(cfg, cfg.channel_id, text, intent.event_marker) do
      {:ok, 201, %{"id" => post_id}} ->
        commit_root(cfg, intent, thread, post_id)

      {:ok, status, body} when status in [401, 403] ->
        park_failed(intent, "unauthorized:#{status}:#{error_hint(body)}")

      {:ok, 429, %{"_retry_after" => seconds}} ->
        defer_rate_limited(intent, seconds)

      # Any 5xx, unknown status or transport error is ambiguous: the post may
      # have been stored. Reconcile by marker instead of blindly retrying.
      {:ok, _status, _} ->
        reconcile_root(cfg, intent, thread)

      {:error, :forbidden_destination} ->
        park_failed(intent, "unconfigured")

      {:error, _} ->
        reconcile_root(cfg, intent, thread)
    end
  end

  defp deliver_reply(cfg, intent, thread, text) do
    case Transport.post(cfg, cfg.channel_id, text, intent.event_marker, thread.root_post_id) do
      {:ok, 201, %{"id" => post_id}} ->
        commit_sent(intent, post_id, thread.root_post_id)

      {:ok, status, body} when status in [401, 403] ->
        park_failed(intent, "unauthorized:#{status}:#{error_hint(body)}")

      {:ok, 429, %{"_retry_after" => seconds}} ->
        defer_rate_limited(intent, seconds)

      # Any 5xx, unknown status or transport error is ambiguous: the post may
      # have been stored. Reconcile by marker instead of blindly retrying.
      {:ok, _status, _} ->
        reconcile_reply(cfg, intent, thread)

      {:error, :forbidden_destination} ->
        park_failed(intent, "unconfigured")

      {:error, _} ->
        reconcile_reply(cfg, intent, thread)
    end
  end

  defp error_hint(%{"message" => message}) when is_binary(message),
    do: String.slice(message, 0, 80)

  defp error_hint(_), do: "remote"

  # Accepted-post/lost-response: the post may exist remotely. Adopt it when
  # the marker is found; park visible uncertainty when history cannot prove
  # the outcome. Never blindly POST again.
  defp reconcile_root(cfg, intent, thread) do
    case Transport.find_by_marker(cfg, cfg.channel_id, intent.event_marker) do
      {:ok, %{"id" => post_id}} ->
        commit_root(cfg, intent, thread, post_id)

      {:ok, nil} ->
        retry_or_park(intent, thread)

      {:error, :unauthorized} ->
        park_failed(intent, "unauthorized")

      {:error, :not_found} ->
        park_failed(intent, "not_found:channel")

      {:error, _} ->
        retry_or_park(intent, thread)
    end
  end

  defp reconcile_reply(cfg, intent, thread) do
    case Transport.find_reply_by_marker(
           cfg,
           cfg.channel_id,
           thread.root_post_id,
           intent.event_marker
         ) do
      {:ok, %{"id" => post_id}} ->
        commit_sent(intent, post_id, thread.root_post_id)

      {:ok, nil} ->
        retry_or_park(intent, thread)

      {:error, :unauthorized} ->
        park_failed(intent, "unauthorized")

      {:error, :not_found} ->
        park_failed(intent, "not_found:channel")

      {:error, _} ->
        retry_or_park(intent, thread)
    end
  end

  defp retry_or_park(intent, thread) do
    if intent.attempts >= @max_attempts do
      park_uncertain(intent, thread, "accepted_post_unconfirmed")
    else
      defer_intent(intent, @retry_delays.timeout, "timeout")
    end
  end

  defp commit_root(cfg, intent, thread, post_id) do
    Operations.transaction(fn ->
      lock_intent(intent.id)
      current = Operations.fetch!(Outbox, intent.id, "Outbox intent not found")
      fence!(current, intent)
      stamp = Operations.now()

      Operations.update(
        current,
        :mark_sent,
        %{claim_run_id: nil, remote_post_id: post_id, remote_root_id: post_id, updated_at: stamp},
        Bridge.actor()
      )

      thread_row = Operations.fetch!(TaskThread, thread.task_id, "Task thread not found")

      # A second root for the same task is reported, not hidden.
      uncertain =
        if is_binary(thread_row.root_post_id) and thread_row.root_post_id != post_id,
          do: "duplicate_root",
          else: nil

      Operations.update(
        thread_row,
        :mark_rooted,
        %{
          channel_id: cfg.channel_id,
          root_post_id: thread_row.root_post_id || post_id,
          expected_marker: intent.event_marker,
          uncertain_reason: uncertain,
          updated_at: stamp
        },
        Bridge.actor()
      )

      %{sent: true, post_id: post_id, duplicate_root: !is_nil(uncertain)}
    end)
    |> unwrap()
  end

  defp commit_sent(intent, post_id, root_id) do
    Operations.transaction(fn ->
      lock_intent(intent.id)
      current = Operations.fetch!(Outbox, intent.id, "Outbox intent not found")
      fence!(current, intent)
      stamp = Operations.now()

      Operations.update(
        current,
        :mark_sent,
        %{claim_run_id: nil, remote_post_id: post_id, remote_root_id: root_id, updated_at: stamp},
        Bridge.actor()
      )

      %{sent: true, post_id: post_id}
    end)
    |> unwrap()
  end

  defp park_uncertain(intent, thread, reason) do
    Operations.transaction(fn ->
      lock_intent(intent.id)
      current = Operations.fetch!(Outbox, intent.id, "Outbox intent not found")
      fence!(current, intent)
      stamp = Operations.now()

      Operations.update(
        current,
        :mark_uncertain,
        %{claim_run_id: nil, uncertain_reason: reason, last_error: reason, updated_at: stamp},
        Bridge.actor()
      )

      thread_row = Operations.fetch!(TaskThread, thread.task_id, "Task thread not found")

      Operations.update(
        thread_row,
        :mark_uncertain,
        %{expected_marker: intent.event_marker, uncertain_reason: reason, updated_at: stamp},
        Bridge.actor()
      )

      %{uncertain: true, reason: reason}
    end)
    |> unwrap()
  end

  defp park_failed(intent, reason) do
    Operations.transaction(fn ->
      lock_intent(intent.id)
      current = Operations.fetch!(Outbox, intent.id, "Outbox intent not found")
      fence!(current, intent)
      stamp = Operations.now()

      Operations.update(
        current,
        :mark_failed,
        %{
          claim_run_id: nil,
          last_error: reason,
          next_eligible_at: DateTime.add(stamp, 3_600),
          updated_at: stamp
        },
        Bridge.actor()
      )

      %{failed: true}
    end)
    |> unwrap()
  end

  defp defer_rate_limited(intent, seconds) do
    seconds = if is_integer(seconds), do: seconds, else: @retry_delays.rate_limited

    case defer_intent(intent, seconds, "rate_limited") do
      {:ok, _} -> {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: seconds)}
      {:error, message} -> {:error, message}
    end
  end

  defp defer_intent(intent, seconds, reason) do
    Operations.transaction(fn ->
      lock_intent(intent.id)
      current = Operations.fetch!(Outbox, intent.id, "Outbox intent not found")
      fence!(current, intent)
      stamp = Operations.now()

      Operations.update(
        current,
        :defer,
        %{
          claim_run_id: nil,
          next_eligible_at: DateTime.add(stamp, seconds),
          last_error: reason,
          updated_at: stamp
        },
        Bridge.actor()
      )

      %{deferred: reason}
    end)
    |> unwrap()
  end

  defp fence!(current, intent) do
    unless current.state == "claimed" and current.generation == intent.generation and
             current.claim_run_id == intent.claim_run_id do
      Operations.reject("conflict", "Outbox claim expired or replaced")
    end
  end

  defp lock_intent(id),
    do:
      Repo.statement!("SELECT id FROM mattermost_outbox WHERE id=$1 FOR UPDATE", [
        Agentboard.Mattermost.Routing.uuid_param(id)
      ])

  defp unwrap({:ok, result}), do: {:ok, result}
  defp unwrap({:error, _code, message}), do: {:error, message}

  defp snooze, do: {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
end
