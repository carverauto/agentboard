defmodule Agentboard.Wake.Reads do
  @moduledoc "Scoped, non-consuming wake inspection; native health is not model activity."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Agent, Message, Task}
  alias Agentboard.Cooperation.{Runtime, Delivery}
  alias Agentboard.Wake.Intent
  require Ash.Query

  def preview(subscription, binding, data) do
    {cursor, limit} = page_params(data)

    rows =
      Intent
      |> Ash.Query.filter(
        recipient_id == ^subscription.id and repo in ^subscription.repos and id > ^cursor
      )
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(limit + 1)
      |> Ash.read!()

    selected = Enum.take(rows, limit)
    stamp = Ops.now()
    agent = Ash.get!(Agent, subscription.id)
    readiness = readiness(subscription, binding, agent, stamp)

    %{
      mode: "dry_run",
      native_delivery_enabled: false,
      intents: Enum.map(selected, &inspect_intent(&1, readiness, stamp)),
      next_cursor: if(length(rows) > limit, do: List.last(selected).id),
      readiness: readiness,
      unsupported_producers: %{
        blocker_shipped: "dependency_events_unavailable (#123)",
        mattermost_post: "worker_version_capture_not_integrated"
      },
      restart: Agentboard.Recovery.readiness(),
      limits: %{source_refs: 32, frame_bytes: 16384, reconcile_seconds: 30, cooldown_seconds: 300}
    }
  end

  defp inspect_intent(row, readiness, stamp) do
    source = canonical_state(row, stamp)

    delivery =
      cond do
        row.delivery_id ->
          Ash.get!(Delivery, row.delivery_id, not_found_error?: false)

        row.cooperation_event_id ->
          Delivery
          |> Ash.Query.filter(
            event_id == ^row.cooperation_event_id and worker_id == ^row.recipient_id
          )
          |> Ash.read_one!()

        true ->
          nil
      end

    disposition =
      cond do
        source != "pending" -> source
        delivery && delivery.state in ~w(handled suppressed) -> delivery.state
        true -> row.state
      end

    %{
      intent_id: row.id,
      intent_revision: row.revision,
      reason: row.reason,
      reason_hash: row.reason_hash,
      recipient_id: row.recipient_id,
      repo: row.repo,
      source: %{
        kind: row.source_kind,
        id: row.source_id,
        version: row.source_version,
        task_id: row.task_id
      },
      source_ref: row.source_ref,
      delivery_id: row.delivery_id,
      disposition: disposition,
      source_state: source,
      eligible: disposition in ~w(pending deferred) and readiness.reason_codes == [],
      reason_codes: readiness.reason_codes,
      dispatch_allowed: false
    }
  end

  # Evaluate canonical facts without changing the retained occurrence or receipt.
  def canonical_state(%{source_kind: "board_message"} = row, _stamp) do
    message = Ash.get!(Message, String.to_integer(row.source_id), not_found_error?: false)

    task =
      if message && message.task_id, do: Ash.get!(Task, message.task_id, not_found_error?: false)

    cond do
      is_nil(task) or Agentboard.WakeIntents.canonical_repo(task.repo) != row.repo ->
        "suppressed"

      is_nil(message) or message.recipient_id != row.recipient_id or
          message.sender_id == row.recipient_id ->
        "suppressed"

      message.read_at ->
        "handled"

      row.source_ref["order_ref"] ->
        # #169 owns current-order/default-tip and repair custody validation.
        # An immutable envelope without its canonical resolver is not authority.
        "unsupported"

      DateTime.to_iso8601(message.created_at) != row.source_version ->
        "suppressed"

      true ->
        "pending"
    end
  end

  def canonical_state(%{source_kind: "decision_wake"} = row, _stamp) do
    wake = Ash.get!(Agentboard.Decisions.Wake, row.source_id, not_found_error?: false)

    request =
      if wake,
        do: Ash.get!(Agentboard.Decisions.Request, wake.request_id, not_found_error?: false)

    task = if wake, do: Ash.get!(Task, wake.task_id, not_found_error?: false)

    cond do
      is_nil(wake) or is_nil(request) or is_nil(task) ->
        "suppressed"

      request.status == "applied" ->
        "handled"

      request.status != "answered" or Agentboard.WakeIntents.canonical_repo(task.repo) != row.repo or
        task.assignee_id != row.recipient_id or
          wake.requester_id != row.recipient_id ->
        "suppressed"

      wake.status in ~w(reserved accepted uncertain) ->
        Map.fetch!(
          %{"reserved" => "reserved", "accepted" => "submitted", "uncertain" => "uncertain"},
          wake.status
        )

      wake.status != "pending" ->
        "suppressed"

      DateTime.to_iso8601(wake.answered_at) != row.source_version ->
        "suppressed"

      true ->
        "pending"
    end
  end

  def canonical_state(%{source_kind: "task_claim"} = row, stamp) do
    task = Ash.get!(Task, row.source_id, not_found_error?: false)

    if (((task && Agentboard.WakeIntents.canonical_repo(task.repo) == row.repo &&
            task.assignee_id == row.recipient_id) and
           task.status in ~w(in_progress blocked review) and
           task.claim_expires_at) && DateTime.compare(task.claim_expires_at, stamp) == :gt) and
         DateTime.to_iso8601(task.claim_expires_at) == row.source_version,
       do: "pending",
       else: "suppressed"
  end

  def canonical_state(%{source_kind: "task_assignment"} = row, _stamp) do
    task = Ash.get!(Task, row.source_id, not_found_error?: false)

    if (task && Agentboard.WakeIntents.canonical_repo(task.repo) == row.repo &&
          task.assignee_id == row.recipient_id) and task.status == "assigned" and
         task.assignment_authorized do
      %{rows: versions} =
        Agentboard.Repo.statement!(
          "SELECT new_revision FROM task_events WHERE task_id=$1 AND kind IN ('assign','handoff') ORDER BY id DESC LIMIT 1",
          [task.id]
        )

      if versions == [[row.source_ref["assignment_revision"]]], do: "pending", else: "suppressed"
    else
      "suppressed"
    end
  end

  def canonical_state(_, _), do: "unsupported"

  defp readiness(s, b, agent, stamp) do
    reasons =
      ["nudge_admission_unavailable (#150)"]
      |> reason(not Runtime.enabled?(s), "cooperation_disabled")
      |> reason(s.paused, "paused")
      |> reason(s.revoked, "revoked")
      |> reason(not is_nil(agent.retired_at), "retired")
      |> reason(not Agentboard.Availability.active?(agent), "agent_unavailable")
      |> reason(is_nil(b.session_id), "unbound")
      |> reason(b.adapter_state != "ready", "adapter_" <> b.adapter_state)
      |> reason(b.connector_state != "healthy", "connector_" <> b.connector_state)
      |> reason(
        is_nil(b.reported_at) or DateTime.diff(stamp, b.reported_at) > 90,
        "connector_stale"
      )
      |> reason(b.adapter not in ~w(pi-native-v1 claude-hook-v1), "safe_input_unproven")

    %{
      host_id: s.host_id,
      worker_id: s.id,
      enrollment_revision: Agentboard.Wake.Transport.enrollment_revision(s),
      binding_epoch: b.epoch,
      session_id: b.session_id,
      adapter_generation: b.pane_id,
      connector_state: b.connector_state,
      adapter_state: b.adapter_state,
      capabilities: b.capabilities,
      reported_at: b.reported_at,
      supported_actions: %{
        inspect: true,
        idle_wake: false,
        receipt: true,
        reconcile: true,
        restart: false
      },
      reason_codes: reasons
    }
  end

  defp reason(reasons, true, reason), do: reasons ++ [reason]
  defp reason(reasons, false, _), do: reasons

  defp page_params(data) do
    cursor = data["cursor"] || "00000000-0000-0000-0000-000000000000"

    limit =
      case data["limit"] || 32 do
        n when is_integer(n) ->
          n

        n when is_binary(n) ->
          case Integer.parse(n) do
            {parsed, ""} -> parsed
            _ -> 0
          end

        _ ->
          0
      end

    unless match?({:ok, _}, Ecto.UUID.cast(cursor)) and limit in 1..32 and
             Enum.all?(Map.keys(data), &(&1 in ~w(cursor limit))),
           do: Ops.reject("invalid_input", "Exact wake cursor and limit 1..32 required")

    {cursor, limit}
  end
end
