defmodule Agentboard.Delivery.Accountability do
  @moduledoc "One unresolved episode per PR; immutable submission provenance, explicit audited responsibility."
  alias Agentboard.{Repo, Cooperation.Runtime}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Delivery.{Obligation, PullRequest, TaskLink}
  alias Agentboard.Board.Resources.Task
  require Ash.Query
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}

  # The collector calls this inside its fenced snapshot/projection transaction.
  def observe(snapshot, result, stamp) do
    id = snapshot.pull_request_id
    lock_pr(id)

    active =
      Obligation
      |> Ash.Query.filter(pull_request_id == ^id and is_nil(resolved_at))
      |> Ash.read_one!()

    cond do
      result.ci_state == "failing" and is_nil(active) ->
        new_episode(id, result, stamp, Map.get(snapshot, :id))

      result.ci_state == "failing" ->
        change(active, %{
          head_sha: result.head_sha,
          snapshot_id: Map.get(snapshot, :id),
          evidence_urls: evidence(result),
          state: if(active.blocker, do: "blocked", else: "unresolved")
        })

      result.ci_state == "passing" and result.payload["policy"] == "verified" and active ->
        change(active, %{state: "resolved", resolved_at: stamp})
        suppress(active)

      active ->
        change(active, %{state: if(active.blocker, do: "blocked", else: "degraded")})

      true ->
        :ok
    end
  end

  defp new_episode(id, result, stamp, snapshot_id) do
    pr = Ash.get!(PullRequest, id)

    links =
      TaskLink
      |> Ash.Query.filter(
        pull_request_id == ^id and
          fragment(
            "NOT EXISTS (SELECT 1 FROM delivery_obligations WHERE repair_task_id = ?)",
            task_id
          )
      )
      |> Ash.read!()

    owners = links |> Enum.map(& &1.submitted_by_id) |> Enum.uniq()
    owner = if length(owners) == 1 and not is_nil(hd(owners)), do: hd(owners)

    %{rows: [[episode]]} =
      Repo.statement!(
        "SELECT coalesce(max(episode),0)+1 FROM delivery_obligations WHERE pull_request_id=$1",
        [id]
      )

    oid = Ash.UUID.generate()
    task_id = "ci-repair-" <> oid
    source_ids = links |> Enum.map(& &1.task_id) |> Enum.join(", ")

    task =
      Ops.create(
        Task,
        :create,
        %{
          id: task_id,
          title: "Repair CI: #{pr.owner}/#{pr.repo} ##{pr.number}",
          description:
            "Confirmed current-head CI failure at #{result.head_sha}. Sources: #{source_ids}. #{pr.url}. Notification handling does not resolve CI.",
          priority: 1,
          repo: pr.owner <> "/" <> pr.repo,
          labels: ["ci-repair"],
          pr_url: pr.url,
          status: "open",
          revision: 1,
          created_at: stamp,
          updated_at: stamp
        },
        @actor
      )

    task =
      if owner do
        Ops.update(
          task,
          :assign,
          %{
            status: "assigned",
            assignee_id: owner,
            assigner_id: "ci-accountability",
            revision: 2,
            updated_at: stamp
          },
          @actor
        )
      else
        task
      end

    Ops.project_event(
      task.id,
      @actor,
      "ci_failure",
      nil,
      nil,
      task.revision,
      %{
        pull_request_id: id,
        episode: episode,
        head_sha: result.head_sha,
        source_tasks: Enum.map(links, & &1.task_id)
      },
      stamp
    )

    obligation =
      Ops.create(
        Obligation,
        :record,
        %{
          id: oid,
          pull_request_id: id,
          episode: episode,
          repair_task_id: task.id,
          responsible_id: owner,
          state: "unresolved",
          head_sha: result.head_sha,
          snapshot_id: snapshot_id,
          evidence_urls: evidence(result),
          last_progress_at: stamp,
          next_reminder_at: DateTime.add(stamp, 900),
          reminder_generation: 0,
          window_at: stamp,
          reminders: 0,
          escalated_at: if(is_nil(owner), do: stamp),
          created_at: stamp
        },
        @actor
      )

    capture(obligation, "failure", owner)
    obligation
  end

  def progress(task, action, data, actor, stamp) do
    obligations =
      Obligation
      |> Ash.Query.filter(
        (repair_task_id == ^task.id or
           fragment(
             "EXISTS (SELECT 1 FROM delivery_task_links l WHERE l.pull_request_id=? AND l.task_id=?)",
             pull_request_id,
             ^task.id
           )) and is_nil(resolved_at)
      )
      |> Ash.read!()

    Enum.each(obligations, fn o ->
      lock_obligation(o.id)
      o = Ash.get!(Obligation, o.id)

      cond do
        o.resolved_at ->
          :ok

        action == "handoff" and o.responsible_id == actor["agent"] ->
          suppress(o)

          o =
            change(o, %{
              responsible_id: data["to"],
              last_progress_at: stamp,
              next_reminder_at: DateTime.add(stamp, 900),
              blocker: nil,
              state: "unresolved"
            })

          capture(o, "handoff-#{task.revision}", data["to"])

        action == "update" and o.repair_task_id == task.id and
            Agentboard.Input.text?(data["note"]) ->
          blocker = if task.status == "blocked", do: data["note"]

          change(o, %{
            last_progress_at: stamp,
            next_reminder_at: DateTime.add(stamp, 900),
            blocker: blocker,
            state: if(blocker, do: "blocked", else: "unresolved"),
            escalated_at: if(blocker, do: stamp)
          })

        true ->
          :ok
      end
    end)
  end

  def responsibility(id, data) do
    Ops.transaction(fn ->
      initial = Ops.fetch!(Obligation, id, "Obligation not found")
      Ops.lock_task(initial.repair_task_id)
      lock_obligation(id)
      o = Ops.fetch!(Obligation, id, "Obligation not found")

      unless Agentboard.Input.slug?(data["to"]) and Agentboard.Input.text?(data["reason"]) and
               Agentboard.Input.slug?(data["idempotency_key"]),
             do: Ops.reject("invalid_input", "Responsible agent, reason and key required")

      Ops.fetch!(Agentboard.Board.Resources.Agent, data["to"], "Register recipient first")
      source_key = "obligation:#{id}:captain-#{data["idempotency_key"]}"

      prior =
        Agentboard.Cooperation.Event
        |> Ash.Query.filter(source_key == ^source_key)
        |> Ash.read_one!()

      if prior do
        unless o.responsible_id == data["to"],
          do: Ops.reject("conflict", "Responsibility key content differs")

        %{obligation: Ops.public(o), idempotent: true}
      else
        if o.responsible_id != data["expected_responsible_id"] or o.resolved_at,
          do: Ops.reject("conflict", "Responsibility changed or episode resolved")

        suppress(o)

        o =
          change(o, %{
            responsible_id: data["to"],
            last_progress_at: Ops.now(),
            next_reminder_at: DateTime.add(Ops.now(), 900),
            blocker: nil
          })

        capture(o, "captain-#{data["idempotency_key"]}", data["to"])
        task = Ops.fetch!(Task, o.repair_task_id, "Repair task missing")

        if task.status not in ~w(done cancelled) do
          task =
            Ops.update(
              task,
              :handoff,
              %{
                status: "assigned",
                assignee_id: data["to"],
                assigner_id: "ci-accountability",
                claimed_at: nil,
                claim_expires_at: nil,
                revision: task.revision + 1,
                updated_at: Ops.now()
              },
              @actor
            )

          Ops.project_event(
            task.id,
            @actor,
            "ci_responsibility_handoff",
            data["reason"],
            task.revision - 1,
            task.revision,
            %{responsible_id: data["to"]},
            Ops.now()
          )
        end

        %{obligation: Ops.public(o), idempotent: false}
      end
    end)
  end

  def bootstrap(subscription) do
    obligations =
      Obligation
      |> Ash.Query.filter(responsible_id == ^subscription.id and is_nil(resolved_at))
      |> Ash.read!()

    Enum.each(obligations, fn o ->
      pr = Ash.get!(PullRequest, o.pull_request_id)

      if String.downcase(pr.owner <> "/" <> pr.repo) in subscription.repos do
        e = capture(o, "failure", subscription.id)

        d =
          Agentboard.Cooperation.Delivery
          |> Ash.Query.filter(event_id == ^e.id and worker_id == ^subscription.id)
          |> Ash.read_one!()

        if is_nil(d),
          do:
            Ops.create(
              Agentboard.Cooperation.Delivery,
              :record,
              %{
                id: Ash.UUID.generate(),
                event_id: e.id,
                worker_id: subscription.id,
                state: "pending",
                created_at: Ops.now()
              },
              @actor
            )
      end
    end)
  end

  def tick do
    Ops.transaction(fn ->
      <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "agentboard-reminder-sweep")
      Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])

      %{rows: rows} =
        Repo.statement!(
          "SELECT id FROM delivery_obligations WHERE resolved_at IS NULL AND next_reminder_at<=clock_timestamp() ORDER BY next_reminder_at,id LIMIT 100 FOR UPDATE SKIP LOCKED",
          []
        )

      Enum.each(rows, fn [id] -> remind(Ash.get!(Obligation, id), Ops.now()) end)
      %{checked: length(rows)}
    end)
  end

  defp remind(o, now) do
    # Unknown/stale provider state stays accountable but does not manufacture a new failure.
    %{rows: states} =
      Repo.statement!("SELECT ci_state,observed_at FROM delivery_poll_states WHERE id=$1", [
        o.pull_request_id
      ])

    current =
      case states do
        [["failing", observed]] when not is_nil(observed) -> DateTime.diff(now, observed) <= 180
        _ -> false
      end

    subscription =
      if o.responsible_id,
        do:
          Ash.get!(Agentboard.Cooperation.Subscription, o.responsible_id, not_found_error?: false)

    %{rows: [[wakes]]} =
      Repo.statement!(
        "SELECT count(*) FROM cooperation_events WHERE kind='ci_reminder' AND $1=ANY(audience) AND created_at>clock_timestamp()-interval '1 hour'",
        [o.responsible_id || ""]
      )

    generation = o.reminder_generation + 1

    can_wake =
      current && is_nil(o.blocker) && !is_nil(subscription) &&
        Runtime.enabled?(subscription) && !subscription.paused && wakes < 4

    if can_wake, do: capture(o, "reminder-#{generation}", o.responsible_id)
    escalated = not can_wake or wakes + 1 >= 4

    if escalated do
      slot = div(DateTime.to_unix(now), 3600)
      capture(o, "digest-#{slot}", "captain")
    end

    change(o, %{
      reminder_generation: generation,
      reminders: if(can_wake, do: o.reminders + 1, else: o.reminders),
      next_reminder_at: DateTime.add(now, if(can_wake, do: 900, else: 3600)),
      escalated_at: if(escalated, do: o.escalated_at || now, else: o.escalated_at)
    })
  end

  defp capture(o, suffix, recipient) do
    pr = Ash.get!(PullRequest, o.pull_request_id)

    kind =
      cond do
        String.starts_with?(suffix, "reminder") -> "ci_reminder"
        String.starts_with?(suffix, "digest") -> "ci_digest"
        true -> "ci_failure"
      end

    Runtime.capture(
      %{
        source_key: "obligation:#{o.id}:#{suffix}",
        kind: kind,
        repo: pr.owner <> "/" <> pr.repo,
        task_id: o.repair_task_id,
        summary:
          "#{pr.url} failed at #{o.head_sha}; repair #{o.repair_task_id}; episode #{o.episode}. Failed jobs: #{Enum.join(o.evidence_urls, ", ")}",
        source_url: pr.url,
        priority: 1
      },
      recipient: recipient || "captain"
    )
  end

  defp suppress(o) do
    %{rows: rows} =
      Repo.statement!(
        "SELECT d.id FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.task_id=$1 AND e.kind IN ('ci_failure','ci_reminder') AND d.state IN ('pending','received') ORDER BY d.id FOR UPDATE OF d",
        [o.repair_task_id]
      )

    Enum.each(rows, fn [id] ->
      d = Ash.get!(Agentboard.Cooperation.Delivery, id)
      Ops.update(d, :change, %{state: "suppressed"}, @actor)
    end)
  end

  defp evidence(result) do
    (result.payload["attempts"] || [])
    |> Enum.filter(&(Map.get(&1, :latest, &1["latest"]) == true))
    |> Enum.map(&Map.get(&1, :source_url, &1["source_url"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp change(o, attrs), do: Ops.update(o, :change, attrs, @actor)

  defp lock_obligation(id),
    do: Repo.statement!("SELECT id FROM delivery_obligations WHERE id::text=$1 FOR UPDATE", [id])

  defp lock_pr(id) do
    Repo.statement!("SELECT id FROM delivery_pull_requests WHERE id=$1 FOR UPDATE", [id])
  end
end
