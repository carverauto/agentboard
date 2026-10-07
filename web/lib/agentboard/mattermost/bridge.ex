defmodule Agentboard.Mattermost.Bridge do
  @moduledoc """
  Capture and routing policy for the outbound lifecycle bridge.

  Cutoff policy: only mutations committed while the bridge code runs capture
  intents. Historical board events never gain intents retroactively, so
  enabling the bridge cannot dump the full board history into chat. New
  activity bridges; old activity stays on the board.
  """

  alias Agentboard.Board.Operations
  alias Agentboard.Mattermost.{Outbox, Routing, TaskThread}

  @routing_revision 1
  @destination_prefix "mattermost:board_thread:"
  @source "board_task_event"
  @max_body_chars 2_000

  # Renewals are lease noise, not lifecycle; heartbeats never reach chat.
  @eligible_actions ~w(create claim assign handoff release reclaim edit link update)
  @max_note_chars 500

  @actor %{"agent" => "mattermost-bridge", "model" => "system", "harness" => "ash"}

  def enabled?, do: Application.get_env(:agentboard, :mattermost_bridge_enabled, false)

  def routing_revision, do: @routing_revision

  def board_channel_id, do: Application.get_env(:agentboard, :mattermost_board_channel_id)

  def base_url, do: Application.get_env(:agentboard, :mattermost_base_url)

  # Called inside the canonical board mutation transaction. A capture failure
  # rolls back the mutation with it; a disabled bridge captures nothing, which
  # is the old-event cutoff: pre-enablement history never gains intents.
  # Idempotent per task event: replays hit the source-intent unique index.
  def capture(task_id, event_id, action, actor, data, stamp)
      when action in @eligible_actions do
    if enabled?() do
      marker = event_marker(task_id, event_id, action)
      run_id = Ash.UUID.generate()

      attrs = %{
        source: @source,
        source_key: "task_event:#{event_id}",
        source_version: 1,
        task_id: task_id,
        event_id: event_id,
        destination: @destination_prefix <> task_id,
        routing_revision: @routing_revision,
        state: "claimed",
        generation: 1,
        claim_run_id: run_id,
        next_eligible_at: stamp,
        event_marker: marker,
        payload: %{
          "action" => action,
          "status" => is_map(data) && data["status"],
          "note" => note_snippet(is_map(data) && data["note"]),
          "actor" => actor["agent"],
          "model" => actor["model"],
          "harness" => actor["harness"]
        },
        created_at: stamp,
        updated_at: stamp
      }

      case Operations.create(Outbox, :capture, Map.put(attrs, :id, Ash.UUID.generate()), @actor) do
        %Outbox{} = intent ->
          ensure_thread(task_id, stamp)
          # Immediate send job in the same transaction: the persisted intent
          # remains authoritative if this notification is lost. Oban unique
          # args deduplicate replays of the same intent.
          Routing.enqueue(intent.id)
          {:ok, intent}
      end
    else
      {:ok, :disabled}
    end
  rescue
    error in [Ash.Error.Invalid, Ash.Error.Unknown, Ash.Error.Forbidden, Postgrex.Error] ->
      if unique_conflict?(error) do
        {:ok, :duplicate}
      else
        reraise error, __STACKTRACE__
      end
  end

  def capture(_task_id, _event_id, _action, _actor, _data, _stamp), do: {:ok, :ineligible}

  defp note_snippet(note) when is_binary(note) and note != "" do
    if String.length(note) > @max_note_chars do
      String.slice(note, 0, @max_note_chars) <> "…"
    else
      note
    end
  end

  defp note_snippet(_), do: nil

  def message(action, task_id, actor, note, status \\ nil) do
    headline =
      if is_binary(status) and status != "" do
        "task #{action} → #{status}: #{task_id} by #{actor["agent"]} (#{actor["harness"]}/#{actor["model"]})"
      else
        "task #{action}: #{task_id} by #{actor["agent"]} (#{actor["harness"]}/#{actor["model"]})"
      end

    body =
      if is_binary(note) and note != "" do
        headline <> "\n" <> truncate(note)
      else
        headline
      end

    body =
      case Application.get_env(:agentboard, :public_board_url) do
        base when is_binary(base) and base != "" ->
          body <> "\nboard: #{String.trim_trailing(base, "/")}/tasks/#{task_id}"

        _ ->
          body
      end

    truncate(body)
  end

  def event_marker(task_id, event_id, action),
    do: "agentboard:#{task_id}:#{event_id}:#{action}"

  defp ensure_thread(task_id, stamp) do
    case Ash.get!(TaskThread, task_id, not_found_error?: false) do
      nil ->
        Operations.create(
          TaskThread,
          :ensure,
          %{
            task_id: task_id,
            channel_id: board_channel_id() || "unconfigured",
            routing_revision: @routing_revision,
            created_at: stamp,
            updated_at: stamp
          },
          @actor
        )

      _thread ->
        :exists
    end
  end

  defp unique_conflict?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(List.wrap(errors), fn
      %Ash.Error.Changes.InvalidAttribute{private_vars: vars} ->
        vars[:constraint_type] == :unique

      _ ->
        false
    end)
  end

  # Narrow: only our source-intent index counts as a replay. Any other
  # unknown failure must surface and roll the mutation back, never masquerade
  # as a duplicate.
  defp unique_conflict?(%Ash.Error.Unknown{errors: errors}) do
    Enum.any?(List.wrap(errors), fn
      %Ash.Error.Unknown.UnknownError{error: message} when is_binary(message) ->
        String.contains?(message, "mattermost_outbox_source_uniq")

      _ ->
        false
    end)
  end

  defp unique_conflict?(%Postgrex.Error{postgres: %{code: :unique_violation} = pg} = err) do
    constraint = Map.get(pg, :constraint) || Map.get(pg, "constraint")

    cond do
      constraint == "mattermost_outbox_source_uniq" -> true
      is_binary(err.message) and String.contains?(err.message, "mattermost_outbox_source_uniq") -> true
      true -> false
    end
  end

  defp unique_conflict?(_), do: false

  defp truncate(text) when byte_size(text) > @max_body_chars do
    String.slice(text, 0, @max_body_chars - 15) <> "…(truncated)"
  end

  defp truncate(text), do: text

  def actor, do: @actor
end
