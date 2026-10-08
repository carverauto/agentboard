defmodule Agentboard.Recovery.Machine do
  @moduledoc """
  Recovery episode contract. This reducer has no native, credential, claim or
  decision side effects. Callers must authenticate observations and re-read
  admission under task/decision/worker locks before persisting a reservation.
  The shipping context only captures dry-run detections: #154/#155/#156 are not ready.
  """
  @terminal ~w(recovered cancelled exhausted)
  @defaults %{
    "mode" => "disabled",
    "approved" => false,
    "id" => nil,
    "version" => nil,
    "cadence_seconds" => nil,
    "minimum_stale_seconds" => 600,
    "cadence_multiplier" => 3,
    "max_attempts" => 3,
    "retry_delays_seconds" => [60, 300],
    "startup_deadline_seconds" => 180,
    "final_action" => "escalate_preserve"
  }

  def policy, do: @defaults

  def detect(candidate, supplied_policy, %DateTime{} = now)
      when is_map(candidate) and is_map(supplied_policy) do
    policy = Map.merge(@defaults, Map.take(supplied_policy, Map.keys(@defaults)))

    with :ok <- policy_valid(policy),
         :ok <- candidate_valid(candidate),
         :ok <- admission(candidate, policy, now) do
      {:ok,
       %{
         id: Ecto.UUID.generate(),
         agent_id: candidate.agent_id,
         host_id: candidate.host_id,
         repo: candidate.repo,
         enrollment_revision: candidate.enrollment_revision,
         binding_epoch: candidate.binding_epoch,
         session_id: candidate.session_id,
         lease_id: candidate.lease_id,
         last_heartbeat_at: candidate.last_heartbeat_at,
         policy_id: policy["id"],
         policy_version: policy["version"],
         policy_snapshot: policy,
         task_ids: candidate.task_ids,
         decision_ids: candidate.decision_ids,
         state: "detected",
         reason: "stale_heartbeat",
         attempt_number: 0,
         budget_used: 0,
         attempt_id: nil,
         attempt_budget_counted: false,
         reserved_at: nil,
         deadline_at: nil,
         next_attempt_at: now,
         new_binding_epoch: nil,
         new_session_id: nil,
         heartbeat_at: nil,
         isolation_verified: false,
         canonical_check_in_complete: false,
         last_host_result: nil,
         reservations_allowed: true,
         escalation_key: nil,
         created_at: now,
         updated_at: now
       }}
    end
  end

  def detect(_, _, _), do: {:error, :invalid_contract}

  def transition(episode, event, %DateTime{} = now) when is_map(episode) and is_map(event) do
    cond do
      episode.state in @terminal -> {:error, :terminal}
      DateTime.compare(now, episode.updated_at) == :lt -> {:error, :clock_regressed}
      true -> apply_event(episode, event, now)
    end
  end

  def transition(_, _, _), do: {:error, :invalid_contract}

  defp apply_event(e, %{type: :reserve}, now) do
    cond do
      not e.reservations_allowed ->
        {:error, :overridden}

      e.policy_snapshot["mode"] != "active" ->
        {:error, :dry_run}

      e.state not in ~w(detected retry_due) ->
        {:error, :effect_unsettled}

      DateTime.compare(now, e.next_attempt_at) == :lt ->
        {:error, :retry_not_due}

      e.budget_used >= e.policy_snapshot["max_attempts"] ->
        {:error, :exhausted}

      true ->
        {:ok,
         %{
           e
           | state: "reserved",
             reason: "restart_reserved",
             attempt_number: e.attempt_number + 1,
             attempt_id: Ecto.UUID.generate(),
             reserved_at: now,
             deadline_at: deadline(e, now),
             next_attempt_at: nil,
             new_binding_epoch: nil,
             new_session_id: nil,
             heartbeat_at: nil,
             isolation_verified: false,
             canonical_check_in_complete: false,
             last_host_result: nil,
             attempt_budget_counted: false,
             updated_at: now
         }}
    end
  end

  defp apply_event(e, %{type: :host_result} = event, now) do
    with :ok <- fence(e, event),
         true <- event[:status] in ~w(still_alive known_absent restarted refused uncertain) do
      cond do
        event.status == e.last_host_result and event.status == "restarted" and
            (event[:new_binding_epoch] != e.new_binding_epoch or
               event[:new_session_id] != e.new_session_id) ->
          {:error, :incarnation_mismatch}

        event.status == e.last_host_result ->
          {:ok, e}

        e.state not in ~w(reserved restarting verifying uncertain) ->
          {:error, :invalid_transition}

        event.status == "restarted" ->
          restarted(e, event, now)

        event.status == "still_alive" and e.state in ~w(reserved restarting) ->
          {:ok,
           %{
             e
             | state: "cancelled",
               reason: "responsive_session_preserved",
               last_host_result: event.status,
               updated_at: now
           }}

        event.status == "known_absent" ->
          failed(e, "known_absent", now)

        event.status == "refused" and event[:effect_absent] == true ->
          failed(e, "host_refused", now)

        true ->
          {:ok,
           %{
             e
             | state: "uncertain",
               reason: "host_effect_unsettled",
               last_host_result: event.status,
               updated_at: now
           }}
      end
    else
      false -> {:error, :invalid_contract}
      error -> error
    end
  end

  defp apply_event(e, %{type: :startup} = event, now) do
    with :ok <- fence(e, event),
         true <- e.state == "verifying",
         true <-
           event[:new_binding_epoch] == e.new_binding_epoch and
             event[:new_session_id] == e.new_session_id,
         true <- event[:lease_id] == e.lease_id and event[:isolation_verified] == true,
         true <- event[:canonical_check_in_complete] == true,
         %DateTime{} = heartbeat <- event[:heartbeat_at],
         true <-
           DateTime.compare(heartbeat, e.reserved_at) == :gt and
             DateTime.compare(heartbeat, now) != :gt,
         true <- DateTime.compare(now, e.deadline_at) != :gt do
      {:ok,
       %{
         e
         | state: "recovered",
           reason: "startup_verified",
           heartbeat_at: heartbeat,
           isolation_verified: true,
           canonical_check_in_complete: true,
           updated_at: now
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :startup_unproven}
    end
  end

  defp apply_event(e, %{type: :heartbeat, heartbeat_at: %DateTime{} = heartbeat}, now) do
    if DateTime.compare(heartbeat, e.last_heartbeat_at) == :gt and
         DateTime.compare(heartbeat, now) != :gt and
         e.state in ~w(detected retry_due),
       do: {:ok, %{e | state: "cancelled", reason: "fresh_before_reservation", updated_at: now}},
       else: {:ok, e}
  end

  defp apply_event(e, %{type: :override}, now) do
    state = if e.state in ~w(detected retry_due), do: "cancelled", else: "uncertain"

    {:ok,
     %{
       e
       | state: state,
         reason: "override_preserve",
         reservations_allowed: false,
         updated_at: now
     }}
  end

  defp apply_event(e, %{type: :timeout}, now) do
    cond do
      e.state not in ~w(reserved restarting verifying uncertain) ->
        {:error, :invalid_transition}

      DateTime.compare(now, e.deadline_at) == :lt ->
        {:error, :deadline_not_due}

      true ->
        used = e.budget_used + 1

        if used >= e.policy_snapshot["max_attempts"],
          do: {:ok, exhausted(e, used, "uncertainty_budget_exhausted", now)},
          else:
            {:ok,
             %{
               e
               | state: "uncertain",
                 budget_used: used,
                 attempt_budget_counted: true,
                 reason: "deadline_unsettled",
                 deadline_at: deadline(e, now),
                 updated_at: now
             }}
    end
  end

  defp apply_event(_, _, _), do: {:error, :invalid_transition}

  defp restarted(e, event, now) do
    if is_integer(event[:new_binding_epoch]) and event.new_binding_epoch > e.binding_epoch and
         is_binary(event[:new_session_id]) and event.new_session_id != "" and
         event.new_session_id != e.session_id and
         DateTime.compare(now, e.deadline_at) != :gt do
      {:ok,
       %{
         e
         | state: if(e.reservations_allowed, do: "verifying", else: "uncertain"),
           reason: if(e.reservations_allowed, do: "spawn_reported", else: "override_preserve"),
           new_binding_epoch: event.new_binding_epoch,
           new_session_id: event.new_session_id,
           last_host_result: event.status,
           updated_at: now
       }}
    else
      {:error, :startup_unproven}
    end
  end

  defp failed(e, reason, now) do
    # A reconciled absence after a timeout consumes the already-counted window,
    # rather than counting an HTTP retry as another native attempt.
    used = if e.attempt_budget_counted, do: e.budget_used, else: e.budget_used + 1

    cond do
      not e.reservations_allowed ->
        {:ok, %{e | state: "cancelled", reason: "override_reconciled", updated_at: now}}

      used >= e.policy_snapshot["max_attempts"] ->
        {:ok, exhausted(e, used, reason, now)}

      true ->
        delay = Enum.at(e.policy_snapshot["retry_delays_seconds"], min(used - 1, 1))

        {:ok,
         %{
           e
           | state: "retry_due",
             reason: reason,
             budget_used: used,
             attempt_budget_counted: true,
             last_host_result: if(reason == "known_absent", do: "known_absent", else: "refused"),
             next_attempt_at: DateTime.add(now, delay, :second),
             updated_at: now
         }}
    end
  end

  defp exhausted(e, used, reason, now),
    do: %{
      e
      | state: "exhausted",
        reason: reason,
        budget_used: used,
        escalation_key: "recovery:" <> e.id,
        updated_at: now
    }

  defp deadline(e, now),
    do: DateTime.add(now, e.policy_snapshot["startup_deadline_seconds"], :second)

  defp fence(e, event) do
    if not is_nil(e.attempt_id) and event[:attempt_id] == e.attempt_id and
         event[:agent_id] == e.agent_id and
         event[:host_id] == e.host_id and event[:enrollment_revision] == e.enrollment_revision and
         event[:expected_binding_epoch] == e.binding_epoch,
       do: :ok,
       else: {:error, :incarnation_mismatch}
  end

  defp policy_valid(p) do
    cond do
      p["mode"] == "disabled" ->
        {:error, :disabled}

      p["mode"] not in ~w(dry_run active) ->
        {:error, :invalid_policy}

      p["approved"] != true ->
        {:error, :unapproved}

      not (is_binary(p["id"]) and p["id"] != "" and is_integer(p["version"]) and p["version"] > 0) ->
        {:error, :invalid_policy}

      not (is_integer(p["cadence_seconds"]) and p["cadence_seconds"] > 0) ->
        {:error, :missing_cadence}

      Enum.any?(
        ~w(minimum_stale_seconds cadence_multiplier max_attempts retry_delays_seconds startup_deadline_seconds final_action),
        &(p[&1] != @defaults[&1])
      ) ->
        {:error, :unapproved_defaults}

      true ->
        :ok
    end
  end

  defp candidate_valid(c) do
    valid =
      Enum.all?(
        [:agent_id, :host_id, :repo, :session_id, :lease_id],
        &(is_binary(c[&1]) and c[&1] != "")
      ) and
        is_integer(c[:enrollment_revision]) and c.enrollment_revision > 0 and
        is_integer(c[:binding_epoch]) and c.binding_epoch > 0 and
        match?(%DateTime{}, c[:last_heartbeat_at]) and is_list(c[:task_ids]) and
        is_list(c[:decision_ids]) and
        Enum.all?(c.task_ids, &(is_binary(&1) and &1 != "")) and
        Enum.all?(c.decision_ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

    if valid, do: :ok, else: {:error, :invalid_contract}
  end

  defp admission(c, p, now) do
    cond do
      c[:enrolled] != true ->
        {:error, :not_enrolled}

      c[:availability] != "active" ->
        {:error, :unavailable}

      c[:paused] != false or c[:revoked] != false ->
        {:error, :paused_or_revoked}

      c[:restart_proven] != true ->
        {:error, :unsupported_session}

      c.task_ids == [] and c.decision_ids == [] ->
        {:error, :no_responsibilities}

      DateTime.diff(now, c.last_heartbeat_at, :second) <
          max(p["minimum_stale_seconds"], p["cadence_multiplier"] * p["cadence_seconds"]) ->
        {:error, :not_stale}

      true ->
        :ok
    end
  end
end
