defmodule Agentboard.Cooperation.IdleContinuation do
  @moduledoc """
  Bounded idle/no-findings continuation (design D6). A reminder is an ordinary
  recipient-pinned cooperation event, so it travels the existing reservation,
  frame and exact-receipt path and is never acknowledged automatically.

  Only enrolled, enabled, unpaused, available, safely idle workers with an
  unresolved scoped responsibility are eligible, and each binding has at most
  one outstanding reminder. After new substantive progress without a Context
  entry, the first reminder invites a useful finding or an explicit
  no-new-finding disposition; it never asks for a publication. Repeated
  reminders without progress and reported provider/model/quota outages enter
  bounded cooldowns with a visible reason. Default off behind its own switch.
  """
  alias Agentboard.{Availability, Input, Repo}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Agent
  alias Agentboard.Cooperation.{Binding, Continuation, Runtime, Subscription}

  @system %{"agent" => "cooperation", "model" => "system", "harness" => "ash"}
  @dispositions ~w(no_new_finding provider_outage model_outage quota_exhausted)
  # Board actions that change a responsibility's recorded state. Claims, renewals
  # and receipts are custody/liveness, not progress.
  @progress_kinds ~w(update link edit handoff note)
  @reminders_before_cooldown 2
  @no_progress_cooldown 3_600
  @outage_cooldown 900
  @cooldown_cap 14_400
  @adapter_failure_window 900
  @recheck 60
  @sweep_limit 100

  def enabled?, do: Application.get_env(:agentboard, :idle_continuation_enabled, false) == true

  defp delay, do: Application.get_env(:agentboard, :idle_continuation_delay_seconds, 600)

  # Scheduler sweep: one short transaction per due worker, so one stalled or
  # failing recipient never blocks another. Pause and revocation are excluded
  # before any read of the worker's state.
  def tick do
    if enabled?() and Application.get_env(:agentboard, :cooperation_enabled, false) do
      %{rows: rows} =
        Repo.statement!(
          "SELECT s.id FROM cooperation_subscriptions s LEFT JOIN cooperation_continuations c ON c.id=s.id WHERE NOT s.revoked AND NOT s.paused AND (c.id IS NULL OR c.next_eligible_at<=clock_timestamp()) ORDER BY c.next_eligible_at NULLS FIRST,s.id LIMIT $1",
          [@sweep_limit]
        )

      outcomes =
        Enum.map(rows, fn [id] ->
          case Ops.transaction(fn -> evaluate(id) end) do
            {:ok, outcome} -> outcome
            {:error, _code, _message} -> :error
          end
        end)

      {:ok,
       %{
         continuation_checked: length(rows),
         continuation_reminders: Enum.count(outcomes, &(&1 == :reminded)),
         continuation_cooldowns: Enum.count(outcomes, &(&1 == :cooldown)),
         continuation_errors: Enum.count(outcomes, &(&1 == :error))
       }}
    else
      {:ok, %{continuation: "disabled"}}
    end
  end

  # Same lock order as a worker request: admission, then worker custody. The
  # sweep captures only; routing inserts the delivery under its own fence.
  defp evaluate(id) do
    Availability.lock_admission()
    Runtime.lock_worker(id)
    s = Ash.get!(Subscription, id, not_found_error?: false)
    b = Ash.get!(Binding, id, not_found_error?: false)
    now = Ops.now()

    cond do
      is_nil(s) or is_nil(b) or s.revoked or s.paused ->
        :skipped

      true ->
        case current(s.id, now) do
          {:created, _row} ->
            :initialized

          {:existing, row} ->
            if DateTime.compare(row.next_eligible_at, now) == :gt,
              do: :not_due,
              else: decide(s, b, row, now)
        end
    end
  end

  defp decide(s, b, row, now) do
    case observe(row, s.id, now) do
      {_row, true} ->
        :progress

      {row, false} ->
        agent = Ash.get!(Agent, s.id)
        work = responsibility(s)

        reasons = suppression(s, b, agent, row, work, now)

        cond do
          reasons != [] ->
            # A busy turn restarts the idle delay; other blocks are rechecked.
            wait = if "agent_not_idle" in reasons, do: delay(), else: @recheck
            Ops.update(row, :defer, %{next_eligible_at: DateTime.add(now, wait)}, @system)
            :suppressed

          row.reminders_since_progress >= @reminders_before_cooldown ->
            cool_down(row, now)

          true ->
            remind(s, row, work, now)
        end
    end
  end

  defp remind(s, row, {task_id, repo}, now) do
    n = row.reminders + 1

    event =
      Runtime.capture(
        %{
          source_key: "idle-continuation:#{s.id}:#{n}",
          kind: "idle_continuation",
          repo: repo,
          task_id: task_id,
          summary: summary(row, task_id),
          source_url: if(task_id, do: "/tasks/" <> URI.encode(task_id), else: "/agents"),
          priority: 2
        },
        recipient: s.id
      )

    change(row, %{
      reminders: n,
      reminders_since_progress: row.reminders_since_progress + 1,
      finding_due: false,
      last_event_id: event.id,
      next_eligible_at: DateTime.add(now, delay()),
      updated_at: now
    })

    :reminded
  end

  # Repeated reminders without recorded progress stop prompting. The cooldown
  # doubles per repetition up to the cap and the escalation stays visible to the
  # captain until new progress; nothing is published on the worker's behalf.
  defp cool_down(row, now) do
    seconds =
      min(@no_progress_cooldown * Integer.pow(2, row.no_progress_cooldowns), @cooldown_cap)

    until = DateTime.add(now, seconds)

    change(row, %{
      cooldown_until: until,
      cooldown_reason: "repeated_no_progress",
      no_progress_cooldowns: row.no_progress_cooldowns + 1,
      reminders_since_progress: 0,
      escalated_at: row.escalated_at || now,
      next_eligible_at: until,
      updated_at: now
    })

    :cooldown
  end

  defp summary(row, task_id) do
    subject = if task_id, do: "responsibility #{task_id}", else: "an unresolved responsibility"

    if row.finding_due do
      "Idle continuation: your last turn recorded progress on #{subject} without a shared finding. " <>
        "If it established something peers can use, publish it with agentboard context publish; " <>
        "otherwise record agentboard worker continuation --disposition no_new_finding. " <>
        "Do not invent findings. This reminder grants no new authority; handle its exact delivery ID."
    else
      "Idle continuation: you are idle with #{subject}. Reconcile its current state, then continue it, " <>
        "record a blocker or handoff, or record an explicit continuation disposition. No publication is " <>
        "required. Reminders pause after #{@reminders_before_cooldown} without recorded progress. " <>
        "This grants no new authority; handle its exact delivery ID."
    end
  end

  # Absorb new attributed progress. New progress lifts cooldowns, a prior
  # no-new-finding disposition and the escalation, and restarts the idle delay.
  defp observe(row, id, now) do
    {event_id, context_id} = watermarks(id)

    if event_id > row.progress_event_id or context_id > row.progress_context_id do
      {change(row, %{
         progress_event_id: event_id,
         progress_context_id: context_id,
         progress_at: now,
         finding_due: context_id == row.progress_context_id,
         reminders_since_progress: 0,
         no_progress_cooldowns: 0,
         outages: 0,
         cooldown_until: nil,
         cooldown_reason: nil,
         escalated_at: nil,
         next_eligible_at: DateTime.add(now, delay()),
         updated_at: now
       }), true}
    else
      {row, false}
    end
  end

  defp watermarks(id) do
    %{rows: [[event_id, context_id]]} =
      Repo.statement!(
        "SELECT coalesce((SELECT max(id) FROM task_events WHERE actor_id=$1 AND kind=ANY($2::text[])),0),coalesce((SELECT max(id) FROM context_entries WHERE source_agent_id=$1),0)",
        [id, @progress_kinds]
      )

    {event_id, context_id}
  end

  # A first observation adopts existing history as the baseline: enrollment
  # never turns old work into fresh progress or an immediate reminder.
  defp current(id, now) do
    case Ash.get!(Continuation, id, not_found_error?: false) do
      nil ->
        {event_id, context_id} = watermarks(id)

        {:created,
         Ops.create(
           Continuation,
           :record,
           %{
             id: id,
             progress_event_id: event_id,
             progress_context_id: context_id,
             next_eligible_at: DateTime.add(now, delay()),
             updated_at: now
           },
           @system
         )}

      row ->
        {:existing, row}
    end
  end

  defp suppression(s, b, agent, row, work, now) do
    []
    |> reason(not Runtime.enabled?(s), "cooperation_disabled")
    |> reason(s.paused, "paused")
    |> reason(s.revoked, "revoked")
    |> reason(not is_nil(agent.retired_at), "retired")
    # Availability carries captain-set quota exhaustion and out-of-service state.
    |> reason(not Availability.active?(agent), "agent_unavailable")
    |> reason(is_nil(b.session_id) or b.epoch < 1, "unbound")
    |> reason(b.adapter_state == "blocked", "approval_blocked")
    |> reason(decision_pending?(s.id), "captain_decision_pending")
    |> reason(b.adapter_state not in ~w(ready blocked), "adapter_" <> b.adapter_state)
    |> reason(b.connector_state != "healthy", "connector_" <> b.connector_state)
    |> reason(Runtime.connector_stale?(b, now), "connector_stale")
    |> reason(agent.reported_status != "idle", "agent_not_idle")
    |> reason(not is_nil(b.active_attempt_id), "submission_requires_reconciliation")
    |> reason(adapter_failure?(s.id), "adapter_failure_cooldown")
    |> reason(cooldown?(row, now), "#{row && row.cooldown_reason}_cooldown")
    |> reason(no_new_finding?(row), "no_new_finding")
    |> reason(is_nil(work), "no_unresolved_responsibilities")
    |> reason(outstanding?(row, s.id), "reminder_outstanding")
  end

  defp cooldown?(nil, _now), do: false

  defp cooldown?(row, now),
    do: not is_nil(row.cooldown_until) and DateTime.compare(row.cooldown_until, now) == :gt

  # Active until new progress is observed after the disposition.
  defp no_new_finding?(nil), do: false

  defp no_new_finding?(row) do
    row.disposition == "no_new_finding" and
      (is_nil(row.progress_at) or DateTime.compare(row.disposition_at, row.progress_at) != :lt)
  end

  defp decision_pending?(id) do
    %{rows: [[pending]]} =
      Repo.statement!(
        "SELECT EXISTS(SELECT 1 FROM decision_requests WHERE requester_id=$1 AND status='open')",
        [id]
      )

    pending
  end

  defp adapter_failure?(id) do
    %{rows: [[failed]]} =
      Repo.statement!(
        "SELECT EXISTS(SELECT 1 FROM cooperation_attempts WHERE worker_id=$1 AND status IN ('uncertain','not_submitted') AND updated_at>clock_timestamp()-make_interval(secs=>$2))",
        [id, @adapter_failure_window]
      )

    failed
  end

  # At most one outstanding reminder per binding, so only the last one can be.
  defp outstanding?(nil, _id), do: false
  defp outstanding?(%{last_event_id: nil}, _id), do: false

  defp outstanding?(row, id) do
    %{rows: [[open]]} =
      Repo.statement!(
        "SELECT EXISTS(SELECT 1 FROM cooperation_events e WHERE e.id=$1::text::uuid AND $2=ANY(e.audience) AND NOT EXISTS(SELECT 1 FROM cooperation_deliveries d WHERE d.event_id=e.id AND d.worker_id=$2 AND d.state IN ('handled','suppressed')))",
        [row.last_event_id, id]
      )

    open
  end

  # Unresolved scoped responsibility: active owned task or an unblocked repair
  # obligation. Blocked tasks and obligations with a recorded blocker wait for
  # their own resolution instead of continuation prompts.
  defp responsibility(s) do
    %{rows: tasks} =
      Repo.statement!(
        "SELECT t.id,lower(CASE WHEN position('/' IN t.repo)>0 THEN t.repo ELSE 'carverauto/' || t.repo END) FROM tasks t WHERE t.assignee_id=$1 AND (t.status IN ('in_progress','review') OR (t.status='assigned' AND t.assignment_authorized)) AND lower(CASE WHEN position('/' IN t.repo)>0 THEN t.repo ELSE 'carverauto/' || t.repo END)=ANY($2::text[]) ORDER BY t.priority,t.id LIMIT 1",
        [s.id, s.repos]
      )

    case tasks do
      [[task_id, repo]] ->
        {task_id, repo}

      [] ->
        %{rows: obligations} =
          Repo.statement!(
            "SELECT nullif(o.repair_task_id,''),lower(p.owner || '/' || p.repo) FROM delivery_obligations o JOIN delivery_pull_requests p ON p.id=o.pull_request_id WHERE o.responsible_id=$1 AND o.resolved_at IS NULL AND o.blocker IS NULL AND lower(p.owner || '/' || p.repo)=ANY($2::text[]) ORDER BY o.created_at,o.id LIMIT 1",
            [s.id, s.repos]
          )

        case obligations do
          [[task_id, repo]] -> {task_id, repo}
          [] -> nil
        end
    end
  end

  # GET /workers/:id/continuation. Read-only: no row is created or advanced.
  def status(s, b) do
    now = Ops.now()
    row = Ash.get!(Continuation, s.id, not_found_error?: false)
    agent = Ash.get!(Agent, s.id)

    reasons =
      []
      |> reason(not enabled?(), "idle_continuation_disabled")
      |> Kernel.++(suppression(s, b, agent, row, responsibility(s), now))
      |> reason(is_nil(row), "not_yet_observed")
      |> reason(
        row && not cooldown?(row, now) && DateTime.compare(row.next_eligible_at, now) == :gt,
        "idle_delay"
      )

    %{
      continuation: %{
        enabled: enabled?(),
        eligible: reasons == [],
        reason_codes: Enum.uniq(reasons),
        state: row && Ops.public(row),
        no_new_finding_active: no_new_finding?(row),
        cooldown_active: cooldown?(row, now),
        escalated: not is_nil(row && row.escalated_at),
        limits: %{
          delay_seconds: delay(),
          reminders_before_cooldown: @reminders_before_cooldown,
          no_progress_cooldown_seconds: @no_progress_cooldown,
          outage_cooldown_seconds: @outage_cooldown,
          cooldown_cap_seconds: @cooldown_cap,
          adapter_failure_window_seconds: @adapter_failure_window
        }
      }
    }
  end

  # POST /workers/:id/continuation. Caller (Runtime.request) holds worker custody.
  # Records an explicit disposition; it never acknowledges a delivery.
  def dispose(s, b, data) do
    unless enabled?(), do: Ops.reject("conflict", "Idle continuation is disabled")

    unless is_map(data) and Enum.sort(Map.keys(data)) == ~w(disposition idempotency_key reason) and
             data["disposition"] in @dispositions and key?(data["idempotency_key"]) and
             Input.text?(data["reason"]) and String.valid?(data["reason"]) and
             byte_size(data["reason"]) <= 512,
           do:
             Ops.reject(
               "invalid_input",
               "Exact disposition, bounded reason and idempotency key required"
             )

    now = Ops.now()
    {_, initial} = current(s.id, now)
    {row, _progressed} = observe(initial, s.id, now)

    if row.disposition_key == data["idempotency_key"] do
      unless row.disposition == data["disposition"] and
               row.disposition_reason == data["reason"],
             do: Ops.reject("conflict", "Disposition key content differs")

      Map.put(status(s, b), :idempotent, true)
    else
      cause = data["disposition"]

      attrs = %{
        disposition: cause,
        disposition_reason: data["reason"],
        disposition_key: data["idempotency_key"],
        disposition_at: now,
        updated_at: now
      }

      attrs =
        if cause == "no_new_finding" do
          Map.put(attrs, :finding_due, false)
        else
          outages = row.outages + 1

          until =
            DateTime.add(now, min(@outage_cooldown * Integer.pow(2, outages - 1), @cooldown_cap))

          Map.merge(attrs, %{
            outages: outages,
            cooldown_until: until,
            cooldown_reason: cause,
            next_eligible_at: Enum.max([row.next_eligible_at, until], DateTime)
          })
        end

      change(row, attrs)
      Map.put(status(s, b), :idempotent, false)
    end
  end

  # Captain-visible dashboard notes; nil when the switch is off or unobserved.
  def notes(id) do
    row = enabled?() && Ash.get!(Continuation, id, not_found_error?: false)

    if row do
      now = Ops.now()

      []
      |> note(
        not is_nil(row.escalated_at),
        "Idle continuation escalated: repeated turns without recorded progress"
      )
      |> note(
        cooldown?(row, now),
        "Idle continuation cooldown (#{row.cooldown_reason}) until #{row.cooldown_until && DateTime.to_iso8601(row.cooldown_until)}"
      )
      |> note(no_new_finding?(row), "Idle continuation suppressed: no new finding recorded")
    end
  end

  defp note(notes, true, text), do: notes ++ [text]
  defp note(notes, _, _), do: notes

  defp change(row, attrs), do: Ops.update(row, :change, attrs, @system)
  defp reason(list, true, code), do: list ++ [code]
  defp reason(list, _, _), do: list
  defp key?(value), do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)
end
