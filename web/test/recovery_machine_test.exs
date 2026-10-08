defmodule Agentboard.RecoveryMachineTest do
  use ExUnit.Case, async: true
  alias Agentboard.Recovery
  alias Agentboard.Recovery.Machine
  @now ~U[2026-01-01 12:00:00Z]
  @decision "1e0c16b8-c29f-4af0-a277-712ba26b6f9a"

  defp candidate do
    %{
      agent_id: "codex-fixture-seat",
      host_id: "fixture-host",
      repo: "example/repo",
      enrollment_revision: 7,
      binding_epoch: 4,
      session_id: "old-native",
      lease_id: "owned-lease",
      last_heartbeat_at: DateTime.add(@now, -600),
      task_ids: ["held-card"],
      decision_ids: [@decision],
      enrolled: true,
      availability: "active",
      paused: false,
      revoked: false,
      restart_proven: true
    }
  end

  defp policy(mode \\ "active"),
    do: %{
      "mode" => mode,
      "approved" => true,
      "id" => "fixture-policy",
      "version" => 1,
      "cadence_seconds" => 120
    }

  defp episode do
    assert {:ok, e} = Recovery.preview(candidate(), policy(), @now)
    e
  end

  defp reserve(e, now \\ @now) do
    assert {:ok, e} = Machine.transition(e, %{type: :reserve}, now)
    e
  end

  defp receipt(e, fields),
    do:
      Map.merge(
        %{
          type: :host_result,
          attempt_id: e.attempt_id,
          agent_id: e.agent_id,
          host_id: e.host_id,
          enrollment_revision: e.enrollment_revision,
          expected_binding_epoch: e.binding_epoch
        },
        fields
      )

  test "default and dry-run paths cannot reserve, and active capture is unavailable" do
    assert {:error, :disabled} = Recovery.preview(candidate(), %{}, @now)
    assert %{mode: "disabled", restart_available: false} = Recovery.readiness()
    assert {:ok, e} = Recovery.preview(candidate(), policy("dry_run"), @now)
    assert {:error, :dry_run} = Machine.transition(e, %{type: :reserve}, @now)

    assert {:error, "unavailable", _} =
             Recovery.capture(candidate(), policy(), %{recovery_internal: true})

    assert {:error, "forbidden", _} =
             Recovery.capture(candidate(), policy("dry_run"), %{"agent" => "codex-fixture-seat"})
  end

  test "admission requires explicit enrollment, active availability, cadence and replacement proof" do
    for {change, error} <- [
          {%{enrolled: false}, :not_enrolled},
          {%{availability: "reserved"}, :unavailable},
          {%{availability: "out_of_service"}, :unavailable},
          {%{paused: true}, :paused_or_revoked},
          {%{revoked: true}, :paused_or_revoked},
          {%{restart_proven: false}, :unsupported_session},
          {%{task_ids: [], decision_ids: []}, :no_responsibilities},
          {%{last_heartbeat_at: DateTime.add(@now, -599)}, :not_stale}
        ] do
      assert {:error, ^error} = Recovery.preview(Map.merge(candidate(), change), policy(), @now)
    end

    assert {:error, :unapproved} =
             Recovery.preview(candidate(), Map.put(policy(), "approved", false), @now)

    assert {:error, :missing_cadence} =
             Recovery.preview(candidate(), Map.delete(policy(), "cadence_seconds"), @now)

    assert {:error, :not_stale} =
             Recovery.preview(candidate(), Map.put(policy(), "cadence_seconds", 240), @now)

    assert {:error, :unapproved_defaults} =
             Recovery.preview(candidate(), Map.put(policy(), "max_attempts", 4), @now)

    assert {:ok, _} =
             Recovery.preview(
               %{candidate() | last_heartbeat_at: DateTime.add(@now, -720)},
               Map.put(policy(), "cadence_seconds", 240),
               @now
             )
  end

  test "ordinary fresh heartbeat cancels before reserve and cannot close a reserved effect" do
    e = episode()
    heartbeat = %{type: :heartbeat, heartbeat_at: @now}
    assert {:ok, %{state: "cancelled"}} = Machine.transition(e, heartbeat, @now)
    e = reserve(e)
    assert {:ok, ^e} = Machine.transition(e, heartbeat, @now)
    assert {:error, :effect_unsettled} = Machine.transition(e, %{type: :reserve}, @now)
  end

  test "three known-absent failures respect backoff and retain one escalation identity and holds" do
    e = reserve(episode())
    assert {:ok, retry} = Machine.transition(e, receipt(e, %{status: "known_absent"}), @now)
    assert retry.next_attempt_at == DateTime.add(@now, 60)
    assert {:ok, ^retry} = Machine.transition(retry, receipt(e, %{status: "known_absent"}), @now)
    assert {:error, :retry_not_due} = Machine.transition(retry, %{type: :reserve}, @now)
    second = reserve(retry, retry.next_attempt_at)

    assert {:ok, retry} =
             Machine.transition(
               second,
               receipt(second, %{status: "known_absent"}),
               second.updated_at
             )

    assert retry.next_attempt_at == DateTime.add(second.updated_at, 300)
    third = reserve(retry, retry.next_attempt_at)

    assert {:ok, final} =
             Machine.transition(
               third,
               receipt(third, %{status: "known_absent"}),
               third.updated_at
             )

    assert %{
             state: "exhausted",
             budget_used: 3,
             attempt_number: 3,
             task_ids: ["held-card"],
             decision_ids: [@decision]
           } = final

    assert final.escalation_key == "recovery:" <> e.id
    assert {:error, :terminal} = Machine.transition(final, %{type: :reserve}, final.updated_at)
  end

  test "lost spawn result spends bounded reconciliation windows without a duplicate attempt" do
    e = reserve(episode())
    assert {:ok, uncertain} = Machine.transition(e, receipt(e, %{status: "uncertain"}), @now)
    assert {:error, :effect_unsettled} = Machine.transition(uncertain, %{type: :reserve}, @now)
    assert {:ok, first} = Machine.transition(uncertain, %{type: :timeout}, uncertain.deadline_at)

    assert {:error, :deadline_not_due} =
             Machine.transition(first, %{type: :timeout}, uncertain.deadline_at)

    assert {:ok, second} = Machine.transition(first, %{type: :timeout}, first.deadline_at)
    assert {:ok, final} = Machine.transition(second, %{type: :timeout}, second.deadline_at)
    assert %{state: "exhausted", budget_used: 3, attempt_number: 1, attempt_id: id} = final
    assert id == e.attempt_id
    assert final.task_ids == e.task_ids and final.decision_ids == e.decision_ids
  end

  test "absence after an earlier attempt's failure charges the new uncertain attempt" do
    e = reserve(episode())
    assert {:ok, first} = Machine.transition(e, receipt(e, %{status: "known_absent"}), @now)
    e = reserve(first, first.next_attempt_at)

    assert {:ok, uncertain} =
             Machine.transition(e, receipt(e, %{status: "uncertain"}), e.updated_at)

    assert {:ok, retry} =
             Machine.transition(uncertain, receipt(e, %{status: "known_absent"}), e.updated_at)

    assert retry.budget_used == 2
  end

  test "new incarnation plus exact lease, fresh heartbeat and catch-up are all required" do
    e = reserve(episode())
    host = receipt(e, %{status: "restarted", new_binding_epoch: 5, new_session_id: "new-native"})

    for {key, value} <- [
          host_id: "foreign",
          enrollment_revision: 6,
          expected_binding_epoch: 3,
          attempt_id: Ecto.UUID.generate()
        ] do
      assert {:error, :incarnation_mismatch} =
               Machine.transition(e, Map.put(host, key, value), @now)
    end

    assert {:error, :startup_unproven} =
             Machine.transition(e, %{host | new_binding_epoch: 4}, @now)

    assert {:ok, verifying} = Machine.transition(e, host, @now)
    assert {:ok, ^verifying} = Machine.transition(verifying, host, @now)

    assert {:error, :incarnation_mismatch} =
             Machine.transition(verifying, %{host | new_session_id: "conflicting-new"}, @now)

    proof =
      receipt(e, %{
        type: :startup,
        new_binding_epoch: 5,
        new_session_id: "new-native",
        lease_id: "owned-lease",
        isolation_verified: true,
        canonical_check_in_complete: true,
        heartbeat_at: DateTime.add(@now, 1)
      })

    now = DateTime.add(@now, 2)

    for {key, value} <- [
          new_session_id: "old-native",
          lease_id: "foreign",
          isolation_verified: false,
          canonical_check_in_complete: false,
          heartbeat_at: @now,
          heartbeat_at: DateTime.add(@now, 3)
        ] do
      assert {:error, :startup_unproven} =
               Machine.transition(verifying, Map.put(proof, key, value), now)
    end

    assert {:ok, %{state: "recovered", task_ids: ["held-card"], decision_ids: [@decision]}} =
             Machine.transition(verifying, proof, now)
  end

  test "manual override prevents new reservations and reconciles an absent effect without escalation" do
    e = reserve(episode())
    assert {:ok, overridden} = Machine.transition(e, %{type: :override}, @now)
    assert {:error, :overridden} = Machine.transition(overridden, %{type: :reserve}, @now)

    assert {:ok, still_overridden} =
             Machine.transition(
               overridden,
               receipt(e, %{
                 status: "restarted",
                 new_binding_epoch: 5,
                 new_session_id: "new-native"
               }),
               @now
             )

    assert still_overridden.state == "uncertain" and not still_overridden.reservations_allowed

    assert {:ok, %{state: "cancelled", escalation_key: nil, task_ids: ["held-card"]}} =
             Machine.transition(overridden, receipt(e, %{status: "known_absent"}), @now)
  end
end

