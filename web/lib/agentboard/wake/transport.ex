defmodule Agentboard.Wake.Transport do
  @moduledoc "Source-first reservation adopting the existing immutable cooperation batch."
  alias Agentboard.{Repo, Availability}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Cooperation.{Runtime, Event}
  alias Agentboard.Wake.{Intent, Attempt, Reads}
  require Ash.Query

  @actor %{
    "agent" => "wake-transport",
    "model" => "system",
    "harness" => "ash",
    :wake_internal => true
  }

  # Called inside Runtime.request after credential authentication and availability,
  # before its worker lock. No provider I/O is performed in this transaction.
  def lock_sources(id, operation, data)
      when operation in ~w(wake_reserve wake_result wake_reconcile) do
    row = occurrence(id, operation, data)

    if row.task_id, do: Ops.lock_task(row.task_id)

    case row.source_kind do
      "decision_wake" ->
        Repo.statement!("SELECT id FROM decision_requests WHERE id=$1::text::uuid FOR UPDATE", [
          row.source_ref["request_id"]
        ])

        Repo.statement!("SELECT id FROM decision_wakes WHERE id=$1::text::uuid FOR UPDATE", [
          row.source_id
        ])

      "board_message" ->
        Repo.statement!("SELECT id FROM messages WHERE id=$1::text::bigint FOR UPDATE", [
          row.source_id
        ])

      _ ->
        :ok
    end

    # Election precedes worker and delivery writes. Source mutation/adoption also
    # owns the canonical source row; no marker-read followed by an unlocked write.
    <<key::signed-64, _::binary>> =
      :crypto.hash(:sha256, "agentboard-wake-election:" <> row.reason_hash)

    Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])
  end

  def lock_sources(_, _, _), do: :ok

  def occurrence(id, operation, data)
      when operation in ~w(wake_reserve wake_result wake_reconcile) do
    if operation == "wake_reserve" do
      fetch_intent!(id, data["intent_id"])
    else
      attempt = fetch_attempt!(id, data["attempt_id"])
      fetch_intent!(id, attempt.intent_id)
    end
  end

  def occurrence(_, _, _), do: nil

  def reserve(data, s, b, reserve_batch, context) do
    exact_keys!(
      data,
      ~w(intent_id intent_revision reason_hash enrollment_revision binding_epoch session_id adapter_generation idempotency_key)
    )

    row = fetch_intent!(s.id, data["intent_id"])
    scope!(row, s)
    key!(data["idempotency_key"])

    prior =
      Attempt
      |> Ash.Query.filter(worker_id == ^s.id and idempotency_key == ^data["idempotency_key"])
      |> Ash.read_one!()

    if prior do
      unless prior.enrollment_revision == enrollment_revision(s) and
               prior.binding_epoch == b.epoch and prior.session_id == b.session_id and
               prior.adapter_generation == b.pane_id and current_attempt?(prior, b),
             do:
               Ops.reject("conflict", "Reservation belongs to a historical recipient or attempt")

      unless prior.intent_id == row.id and
               prior.reservation["intent_revision"] == data["intent_revision"] and
               prior.reservation["reason_hash"] == data["reason_hash"] and
               prior.enrollment_revision == data["enrollment_revision"] and
               prior.binding_epoch == data["binding_epoch"] and
               prior.session_id == data["session_id"] and
               prior.adapter_generation == data["adapter_generation"],
             do: Ops.reject("conflict", "Wake reservation key content differs")

      cooperative = Ash.get!(Agentboard.Cooperation.Attempt, prior.cooperation_attempt_id)
      batch = Ash.get!(Agentboard.Cooperation.Batch, cooperative.batch_id)

      %{
        reservation: public_reservation(prior),
        batch: Runtime.batch_record(batch, cooperative),
        attempt: Ops.public(prior),
        idempotent: true
      }
    else
      reserve_new(row, data, s, b, reserve_batch, context)
    end
  end

  defp reserve_new(row, data, s, b, reserve_batch, context) do
    unless row.revision == data["intent_revision"] and row.reason_hash == data["reason_hash"] and
             enrollment_revision(s) == data["enrollment_revision"] and
             b.epoch == data["binding_epoch"] and
             b.session_id == data["session_id"] and b.pane_id == data["adapter_generation"],
           do: Ops.reject("conflict", "Wake source or recipient fence changed")

    reasons = admission(row, s, b, context)

    if reasons != [] do
      %{reservation: nil, reason_codes: reasons, native_delivery_enabled: false}
    else
      delivery = adopt(row, s)

      if delivery.state in ~w(handled suppressed) do
        change(row, %{state: delivery.state, reason_code: "existing_delivery_resolved"})

        %{
          reservation: nil,
          reason_codes: ["existing_delivery_resolved"],
          native_delivery_enabled: false
        }
      else
        case reserve_batch.([delivery]) do
          %{batch: nil} = result -> result |> Map.put(:reservation, nil)
          %{batch: batch} -> record_attempt(row, data, s, b, delivery, batch)
        end
      end
    end
  end

  defp admission(row, s, b, context) do
    stamp = Ops.now()
    agent = Availability.admission_agent(s.id)
    source = Reads.canonical_state(row, stamp, context)

    []
    |> reason(
      not Application.get_env(:agentboard, :wake_delivery_enabled, false),
      "wake_delivery_disabled"
    )
    |> reason(not Runtime.enabled?(s), "cooperation_disabled")
    |> reason(s.paused, "paused")
    |> reason(not is_nil(agent.retired_at), "retired")
    |> reason(not Availability.active?(agent), "agent_unavailable")
    |> reason(row.reason == "idle_assigned" and agent.reported_status != "idle", "agent_not_idle")
    |> reason(is_nil(b.session_id) or b.epoch < 1, "unbound")
    |> reason(
      b.adapter_state != "ready" or b.connector_state != "healthy",
      "native_boundary_unavailable"
    )
    |> reason(
      is_nil(b.reported_at) or DateTime.diff(stamp, b.reported_at) > 90,
      "connector_stale"
    )
    |> reason(b.adapter not in ~w(pi-native-v1 claude-hook-v1), "safe_input_unproven")
    |> reason(get_in(b.capabilities, ["idle_wake", "supported"]) != true, "idle_wake_unsupported")
    |> reason(source != "pending", "source_" <> source)
    |> reason(row.state not in ~w(pending deferred), "intent_requires_reconciliation")
    |> reason(not is_nil(b.active_attempt_id), "submission_requires_reconciliation")
    |> reason(cooldown?(row, s, stamp), "ordinary_cooldown")
  end

  defp cooldown?(%{reason: reason}, _s, _stamp) when reason in ~w(unread_dm decision_answered),
    do: false

  defp cooldown?(_row, s, stamp) do
    cutoff = DateTime.add(stamp, -300)

    Attempt
    |> Ash.Query.filter(
      worker_id == ^s.id and state in ["reserved", "submitted", "uncertain"] and
        created_at > ^cutoff
    )
    |> Ash.exists?()
  end

  defp adopt(row, s) do
    event =
      if row.cooperation_event_id do
        Ops.fetch!(Event, row.cooperation_event_id, "Original cooperation event missing")
      else
        {key, summary} = source_event(row)

        Runtime.capture(
          %{
            source_key: key,
            kind: row.reason,
            repo: row.repo,
            task_id: row.task_id,
            summary: summary,
            source_url: source_url(row),
            priority: if(row.reason in ~w(unread_dm decision_answered), do: 1, else: 2)
          },
          recipient: s.id
        )
      end

    if row.source_kind == "decision_wake" do
      wake =
        Ops.fetch!(Agentboard.Decisions.Wake, row.source_id, "Original decision wake missing")

      if wake.route == "seat_watcher" do
        unless wake.status == "pending",
          do: Ops.reject("conflict", "Fallback wake already reserved")

        Ops.update(
          wake,
          :adopt,
          %{route: "worker", worker_event_id: event.id, worker_id: s.id, updated_at: Ops.now()},
          @actor
        )
      end
    end

    delivery = Runtime.ensure_delivery(event, s.id, @actor)
    change(row, %{cooperation_event_id: event.id, delivery_id: delivery.id})
    delivery
  end

  defp source_event(%{source_kind: "decision_wake"} = row),
    do:
      {row.source_ref["source_key"],
       "Captain answered decision #{row.source_ref["request_id"]}. Read decision show; apply then ack."}

  defp source_event(row),
    do:
      {"wake:" <> row.reason_hash,
       "#{row.reason}: reconcile canonical #{row.source_kind} #{row.source_id}; handle exact IDs explicitly."}

  defp source_url(%{source_kind: "board_message"} = row), do: "/messages/#{row.source_id}"
  defp source_url(row), do: "/tasks/#{URI.encode(row.task_id || row.source_id)}"

  defp record_attempt(row, data, s, b, delivery, batch) do
    stamp = Ops.now()

    recipient = %{
      "agent_id" => s.id,
      "host_id" => s.host_id,
      "repo" => row.repo,
      "enrollment_revision" => enrollment_revision(s),
      "binding_epoch" => b.epoch,
      "session_id" => b.session_id,
      "adapter_generation" => b.pane_id
    }

    source = %{"kind" => row.source_kind, "id" => row.source_id, "version" => row.source_version}
    source = if row.task_id, do: Map.put(source, "task_id", row.task_id), else: source
    ref = source |> Map.delete("task_id") |> Map.put("delivery_id", delivery.id)

    ref =
      if row.source_ref["order_ref"],
        do: Map.put(ref, "order_ref", row.source_ref["order_ref"]),
        else: ref

    reservation = %{
      "protocol_revision" => 1,
      "intent_id" => row.id,
      "intent_revision" => row.revision,
      "effect" => "wake.nudge",
      "reason" => row.reason,
      "reason_hash" => row.reason_hash,
      "recipient" => recipient,
      "source" => source,
      "attempt_id" => batch.attempt_id,
      "expires_at" => batch.lease_expires_at,
      "source_refs" => [ref]
    }

    hash =
      [
        "agentboard-wake-reservation-v1",
        row.id,
        row.revision,
        row.reason_hash,
        s.id,
        s.host_id,
        row.repo,
        enrollment_revision(s),
        b.epoch,
        b.session_id,
        b.pane_id,
        batch.attempt_id,
        batch.payload_hash,
        row.source_kind,
        row.source_id,
        row.source_version,
        delivery.id
      ]
      |> Jason.encode!()
      |> digest()

    reservation = Map.put(reservation, "payload_hash", hash) |> json_map()

    attempt =
      Ops.create(
        Attempt,
        :record,
        %{
          id: batch.attempt_id,
          intent_id: row.id,
          worker_id: s.id,
          host_id: s.host_id,
          enrollment_revision: enrollment_revision(s),
          binding_epoch: b.epoch,
          session_id: b.session_id,
          adapter_generation: b.pane_id,
          cooperation_attempt_id: batch.attempt_id,
          idempotency_key: data["idempotency_key"],
          payload_hash: hash,
          reservation:
            Map.put(reservation, "cooperation_fences", %{
              "binding_epoch" => batch.binding_epoch,
              "dispatch_generation" => batch.dispatch_generation,
              "payload_hash" => batch.payload_hash
            }),
          state: "reserved",
          reason_codes: [],
          evidence_refs: [],
          expires_at: batch.lease_expires_at,
          created_at: stamp,
          updated_at: stamp
        },
        @actor
      )

    change(Ash.get!(Intent, row.id), %{state: "reserved", reason_code: nil})

    %{
      reservation: public_reservation(attempt),
      batch: batch,
      attempt: Ops.public(attempt),
      idempotent: false
    }
  end

  def result(data, s, b, commit_result) do
    exact_keys!(
      data,
      ~w(attempt_id intent_id reason_hash payload_hash recipient status reason_codes evidence_refs)
    )

    a = matching_attempt!(data, s)

    unless data["status"] in ~w(submitted not_submitted uncertain) and
             codes?(data["reason_codes"], 16, 96) and
             codes?(data["evidence_refs"], 8, 240) and
             (data["status"] == "uncertain" or data["evidence_refs"] != []),
           do:
             Ops.reject(
               "invalid_input",
               "Bounded transport disposition and positive evidence references required"
             )

    unless a.enrollment_revision == enrollment_revision(s) and a.binding_epoch == b.epoch and
             a.session_id == b.session_id and a.adapter_generation == b.pane_id,
           do:
             Ops.reject(
               "conflict",
               "Old-incarnation result retained for historical reconciliation"
             )

    if a.state == data["status"] and
         (a.reason_codes != data["reason_codes"] or a.evidence_refs != data["evidence_refs"]),
       do: Ops.reject("conflict", "Committed wake transport evidence differs")

    body =
      Map.merge(a.reservation["cooperation_fences"], %{
        "attempt_id" => a.cooperation_attempt_id,
        "status" => data["status"],
        "reason" =>
          "wake evidence sha256:" <>
            digest(
              Jason.encode!(%{
                reason_codes: data["reason_codes"],
                evidence_refs: data["evidence_refs"]
              })
            )
      })

    outcome = commit_result.(body)
    cooperative = Ash.get!(Agentboard.Cooperation.Attempt, a.cooperation_attempt_id)

    a =
      if a.state == "handled" or not current_attempt?(a, b),
        do: a,
        else: sync(a, cooperative.status, data["reason_codes"], data["evidence_refs"])

    %{reservation: public_reservation(a), attempt: Ops.public(a), cooperation: outcome}
  end

  def reconcile(data, s, b, reconcile_batch) do
    exact_keys!(data, ~w(attempt_id intent_id reason_hash payload_hash recipient))
    a = matching_attempt!(data, s)

    outcome =
      reconcile_batch.(
        Map.put(a.reservation["cooperation_fences"], "attempt_id", a.cooperation_attempt_id)
      )

    cooperative = Ash.get!(Agentboard.Cooperation.Attempt, a.cooperation_attempt_id)

    a =
      if outcome.historical or not current_attempt?(a, b),
        do: a,
        else: sync(a, cooperative.status, a.reason_codes, a.evidence_refs)

    %{reservation: public_reservation(a), attempt: Ops.public(a), cooperation: outcome}
  end

  # Terminal retries are idempotent, but never own a later reservation's state.
  defp current_attempt?(a, b) do
    a.binding_epoch == b.epoch and
      a.reservation["cooperation_fences"]["dispatch_generation"] == b.generation
  end

  defp sync(a, state, codes, refs) do
    a =
      if a.state != state or a.reason_codes != codes or a.evidence_refs != refs,
        do:
          Ops.update(
            a,
            :change,
            %{state: state, reason_codes: codes, evidence_refs: refs, updated_at: Ops.now()},
            @actor
          ),
        else: a

    row = Ash.get!(Intent, a.intent_id)
    state = if state == "not_submitted", do: "pending", else: state
    if row.state != state, do: change(row, %{state: state, reason_code: List.first(codes)})
    a
  end

  defp matching_attempt!(data, s) do
    a = fetch_attempt!(s.id, data["attempt_id"])
    scope!(Ash.get!(Intent, a.intent_id), s)

    unless a.intent_id == data["intent_id"] and
             a.reservation["reason_hash"] == data["reason_hash"] and
             a.payload_hash == data["payload_hash"] and
             a.reservation["recipient"] == data["recipient"],
           do: Ops.reject("conflict", "Exact immutable wake and recipient fences required")

    a
  end

  defp fetch_intent!(id, key) do
    uuid!(key)
    row = Ops.fetch!(Intent, key, "Wake intent not found")
    if row.recipient_id != id, do: Ops.reject("forbidden", "Foreign wake recipient")
    row
  end

  defp fetch_attempt!(id, key) do
    uuid!(key)
    row = Ops.fetch!(Attempt, key, "Wake attempt not found")
    if row.worker_id != id, do: Ops.reject("forbidden", "Foreign wake attempt")
    row
  end

  defp scope!(row, s),
    do:
      if(row.repo not in s.repos,
        do: Ops.reject("forbidden", "Wake outside enrollment repositories")
      )

  def enrollment_revision(s), do: DateTime.to_unix(s.enrolled_at, :microsecond)
  defp public_reservation(a), do: Map.delete(a.reservation, "cooperation_fences")

  defp change(row, attrs),
    do:
      Ops.update(
        row,
        :change,
        Map.merge(attrs, %{revision: row.revision + 1, updated_at: Ops.now()}),
        @actor
      )

  defp exact_keys!(data, keys),
    do:
      if(not is_map(data) or Enum.sort(Map.keys(data)) != Enum.sort(keys),
        do: Ops.reject("invalid_input", "Exact wake fields required")
      )

  defp uuid!(key),
    do:
      if(not match?({:ok, _}, Ecto.UUID.cast(key)),
        do: Ops.reject("invalid_input", "Wake UUID required")
      )

  defp key!(key),
    do:
      if(not is_binary(key) or byte_size(key) not in 1..128,
        do: Ops.reject("invalid_input", "Bounded idempotency key required")
      )

  defp codes?(items, count, size),
    do:
      is_list(items) and length(items) <= count and
        Enum.all?(items, &(is_binary(&1) and String.valid?(&1) and byte_size(&1) in 1..size))

  defp reason(reasons, true, code), do: reasons ++ [code]
  defp reason(reasons, false, _), do: reasons
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp json_map(value), do: value |> Jason.encode!() |> Jason.decode!()
end
