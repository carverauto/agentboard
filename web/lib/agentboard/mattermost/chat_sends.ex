defmodule Agentboard.Mattermost.ChatSends do
  @moduledoc """
  Spool-backed generic chat sends (OpenSpec 5.2).

  A send is reserved in `ChatSpool` before Mattermost sees it. A definitive
  rejection fails it; an ambiguous response (timeout, 5xx, closed connection)
  is reconciled against channel history by the send's `msg_id` prop before
  anything is posted again. A miss parks the send as `uncertain` with a
  reason; it then needs an explicit `reconcile`, `retry` (records a possible
  duplicate) or `abandon`. Remote exactly-once posting is not promised.
  """
  alias Agentboard.Mattermost.{ChatSpool, Conversations, Transport}

  @unresolved ~w(submitting uncertain expired)
  @actions ~w(reconcile retry abandon)

  def unresolved?(%{"state" => state}), do: state in @unresolved
  def unresolved?(_), do: false

  # `spec` carries the validated request plus the caller's agent id and a
  # fresh msg_id. Returns `{:ok, receipt}` or `{:error, code, message}`.
  def post(cfg, spec) do
    case ChatSpool.by_key(spec.agent_id, spec.retry_key) do
      nil -> fresh(cfg, spec)
      row -> resume(cfg, row, spec)
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      # A failure after the network call leaves the row `submitting`, so the
      # same retry key reconciles it later instead of reposting.
      {:error, "unavailable",
       "Chat spool is unavailable; re-run with the same retry key to reconcile"}
  end

  def status(agent_id, msg_id) do
    case own(agent_id, msg_id) do
      nil -> {:error, "not_found", "Send not found"}
      row -> {:ok, %{"send" => ChatSpool.public(row)}}
    end
  end

  def list(agent_id, state) do
    states =
      case state do
        s when s in [nil, ""] -> ~w(submitting uncertain expired failed)
        s when s in ~w(submitting sent uncertain failed abandoned expired) -> [s]
        _ -> :invalid
      end

    if states == :invalid,
      do: {:error, "invalid_input", "state must be a spool state"},
      else:
        {:ok, %{"sends" => Enum.map(ChatSpool.list(agent_id, states, 100), &ChatSpool.public/1)}}
  end

  def channel_of(agent_id, msg_id) do
    case own(agent_id, msg_id) do
      nil -> {:error, "not_found", "Send not found"}
      row -> {:ok, row.channel_id}
    end
  end

  def resolve(cfg, agent_id, msg_id, action) when action in @actions do
    case own(agent_id, msg_id) do
      nil -> {:error, "not_found", "Send not found"}
      row -> resolve_row(cfg, row, action)
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, "unavailable", "Chat spool is unavailable"}
  end

  def resolve(_cfg, _agent_id, _msg_id, _action),
    do: {:error, "invalid_input", "action must be one of #{Enum.join(@actions, ", ")}"}

  # Message text and props are derived from stored fields only, so a manual
  # retry reproduces the original post exactly (same msg_id marker).
  def message(spec) do
    header = "[#{spec.agent_id} · #{spec.task_id}]"
    address = if is_binary(spec.recipient_id), do: "@#{spec.recipient_id} ", else: ""
    header <> "\n" <> address <> spec.body
  end

  def props(spec) do
    props = %{
      "agent_id" => spec.agent_id,
      "task_id" => spec.task_id,
      "kind" => spec.kind,
      "msg_id" => spec.msg_id,
      "agentboard_retry_key" => spec.retry_key
    }

    if is_binary(spec.recipient_id),
      do: Map.put(props, "recipient_id", spec.recipient_id),
      else: props
  end

  defp own(agent_id, msg_id) when is_binary(msg_id) and byte_size(msg_id) in 1..128 do
    case ChatSpool.fetch(msg_id) do
      %{agent_id: ^agent_id} = row -> row
      _ -> nil
    end
  end

  defp own(_agent_id, _msg_id), do: nil

  # A retry key may name a post made before the spool existed, or one whose
  # spool row already expired: bounded adoption from history comes first.
  defp fresh(cfg, spec) do
    case Conversations.adopt_retry(cfg, spec.channel_id, spec.retry_key, spec.agent_id) do
      {:ok, nil} ->
        case ChatSpool.reserve(spec) do
          {:new, row} -> submit(cfg, row, spec, false)
          {:existing, row} -> resume(cfg, row, spec)
        end

      {:ok, post} ->
        adopted = Map.put(spec, :msg_id, get_in(post, ["props", "msg_id"]) || spec.msg_id)
        :ok = ChatSpool.record_adopted(adopted, post["id"])
        spool = ChatSpool.by_key(spec.agent_id, spec.retry_key) |> ChatSpool.public()

        {:ok,
         %{
           "duplicate" => true,
           "post" => post,
           "msg_id" => adopted.msg_id,
           "state" => "sent",
           "reason" => nil,
           "spool" => spool
         }}

      {:error, _code, _message} = error ->
        error
    end
  end

  defp resume(cfg, row, spec) do
    cond do
      row.channel_id != spec.channel_id ->
        {:error, "conflict", "Retry key belongs to a send in another channel"}

      row.state == "sent" ->
        {:ok, receipt(row, posted(row), true)}

      row.state == "abandoned" ->
        {:error, "conflict", "Retry key was abandoned; send again with a new retry key"}

      # Definitively not posted: the same key may carry the send again.
      row.state == "failed" ->
        case ChatSpool.resubmit(row.msg_id, ["failed"], spec.body, nil) do
          {:ok, row} -> submit(cfg, row, %{stored(row) | body: spec.body}, true)
          {:stale, row} -> resume(cfg, row, spec)
        end

      row.state in ~w(uncertain expired) or ChatSpool.stale_submission?(row) ->
        reconcile(cfg, row, true)

      # Another request owns the in-flight submission.
      true ->
        {:ok, receipt(row, nil, false)}
    end
  end

  defp resolve_row(cfg, row, "reconcile") do
    if row.state in ~w(uncertain expired) or ChatSpool.stale_submission?(row),
      do: reconcile(cfg, row, true),
      else: {:ok, receipt(row, posted(row), row.state == "sent")}
  end

  defp resolve_row(cfg, row, "retry") do
    if row.state == "uncertain" or ChatSpool.stale_submission?(row) do
      # Reconcile first: a post that appeared since is adopted, never repeated.
      case reconcile(cfg, row, true) do
        {:ok, %{"state" => "uncertain"}} -> manual_retry(cfg, ChatSpool.fetch(row.msg_id))
        other -> other
      end
    else
      {:error, "conflict", retry_refusal(row.state)}
    end
  end

  defp resolve_row(_cfg, row, "abandon") do
    if row.state in ~w(uncertain expired failed) or ChatSpool.stale_submission?(row) do
      case ChatSpool.mark_abandoned(row.msg_id, [row.state]) do
        {:ok, row} -> {:ok, receipt(row, nil, false)}
        {:stale, _} -> {:error, "conflict", "Send changed concurrently; inspect it again"}
      end
    else
      {:error, "conflict", "Only unresolved or failed sends can be abandoned"}
    end
  end

  defp retry_refusal("sent"), do: "Send is already verified"

  defp retry_refusal("expired"),
    do: "Spooled body expired; abandon and send again with a new retry key"

  defp retry_refusal("failed"), do: "Send failed definitively; send it again"
  defp retry_refusal(_), do: "Only an uncertain send can be retried"

  # The operator explicitly chose availability: the resolution records the
  # possible duplicate, and the identical msg_id lets a later reconcile flag it.
  defp manual_retry(cfg, %{state: "uncertain"} = row) do
    with {:ok, body} <- ChatSpool.body(row.msg_id),
         {:ok, row} <-
           ChatSpool.resubmit(row.msg_id, ["uncertain"], body, "manual_retry_possible_duplicate") do
      submit(cfg, row, %{stored(row) | body: body}, false)
    else
      :expired -> {:error, "conflict", retry_refusal("expired")}
      {:stale, _} -> {:error, "conflict", "Send changed concurrently; inspect it again"}
    end
  end

  defp manual_retry(_cfg, row), do: {:ok, receipt(row, posted(row), false)}

  defp submit(cfg, row, spec, duplicate?) do
    case Conversations.submit(
           cfg,
           spec.agent_id,
           spec.channel_id,
           message(spec),
           props(spec),
           spec.root_id,
           Map.get(spec, :icon_url)
         ) do
      {:sent, post} ->
        case ChatSpool.mark_sent(row.msg_id, ["submitting"], post["id"]) do
          {:ok, row} -> {:ok, receipt(row, post, duplicate?)}
          {:stale, row} -> {:ok, receipt(row, post, duplicate?)}
        end

      {:rejected, code, message, reason} ->
        _ = ChatSpool.mark_failed(row.msg_id, ["submitting"], reason)
        {:error, code, message}

      {:ambiguous, _reason} ->
        reconcile(cfg, ChatSpool.fetch(row.msg_id), duplicate?)
    end
  end

  # Accepted-post/lost-response: adopt the post carrying this msg_id, report
  # extra copies as duplicates, or park visible uncertainty. A history miss is
  # never treated as proof that nothing was posted.
  defp reconcile(cfg, row, duplicate?) do
    from = [row.state]

    case Transport.find_by_msg_id(cfg, row.channel_id, row.msg_id, row.agent_id) do
      {:ok, [_ | _] = posts, _complete} ->
        [first | rest] = Enum.sort_by(posts, &{&1["create_at"] || 0, &1["id"]})
        resolution = if rest == [], do: "reconciled", else: "reconciled_duplicate"

        case ChatSpool.mark_sent(
               row.msg_id,
               from,
               first["id"],
               resolution,
               Enum.map(rest, & &1["id"])
             ) do
          {:ok, row} -> {:ok, receipt(row, first, duplicate?)}
          {:stale, row} -> {:ok, receipt(row, first, duplicate?)}
        end

      {:ok, [], true} ->
        park(row, "post_not_observed")

      {:ok, [], false} ->
        park(row, "history_incomplete")

      {:error, :unauthorized} ->
        park(row, "history_unauthorized")

      {:error, _} ->
        park(row, "history_unavailable")
    end
  end

  # Expired rows keep their state (no body remains to retry); everything
  # else becomes explicitly uncertain with the reason it could not be proven.
  defp park(%{state: "expired"} = row, _reason), do: {:ok, receipt(row, nil, false)}

  defp park(row, reason) do
    case ChatSpool.mark_uncertain(row.msg_id, [row.state], reason) do
      {:ok, row} -> {:ok, receipt(row, nil, false)}
      {:stale, row} -> {:ok, receipt(row, posted(row), false)}
    end
  end

  defp stored(row) do
    %{
      agent_id: row.agent_id,
      channel_id: row.channel_id,
      root_id: row.root_id,
      task_id: row.task_id,
      kind: row.kind,
      retry_key: row.retry_key,
      recipient_id: row.recipient_id,
      msg_id: row.msg_id,
      body: nil
    }
  end

  defp posted(%{state: "sent", post_id: post_id, channel_id: channel_id}),
    do: %{"id" => post_id, "channel_id" => channel_id}

  defp posted(_row), do: nil

  defp receipt(row, post, duplicate?) do
    %{
      "duplicate" => duplicate? and row.state == "sent",
      "post" => post,
      "msg_id" => row.msg_id,
      "state" => row.state,
      "reason" => row.reason,
      "spool" => ChatSpool.public(row)
    }
  end
end
