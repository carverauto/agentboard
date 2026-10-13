defmodule Agentboard.FleetRefill do
  @moduledoc """
  Deterministic backlog refill for captain-activated fleets (issue #170).

  Pure server code: a minute schedule and task done/release/handoff events run
  the same idempotent pass. There is no coordinator, prompt loop or scan
  cursor; every pass reselects unassigned open cards. Default off behind
  `AGENTBOARD_REFILL_ENABLED`; each fleet also needs a captain activation.
  Deactivation stops new assignments and returns; it never releases claims.
  """
  alias Agentboard.{Availability, Captain, Decisions, Eligibility, Repo, SeatScope}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Task
  alias Agentboard.Board.Transition
  alias Agentboard.FleetLoadout.{Activation, Configuration}
  alias Agentboard.FleetRefill.{Assignment, Pass, Wake}
  require Ash.Query

  @system %{
    "agent" => "fleet-refill",
    "model" => "system",
    "harness" => "ash",
    :fleet_refill => true
  }
  @captain %{
    "agent" => "captain",
    "model" => "human",
    "harness" => "captain",
    :fleet_admin => true
  }
  @default_deadline 1800
  @card_limit 100

  def enabled?, do: Application.get_env(:agentboard, :refill_enabled, false) == true

  # Cards carrying one of these labels go only to seats whose managed scope
  # names the label in required_labels or allowed_labels.
  def restricted_labels,
    do: Application.get_env(:agentboard, :refill_restricted_labels, ["security"])

  ## Captain activation

  def activate(id, capability, data) do
    with :ok <- authority(capability),
         :ok <- fleet_id(id),
         {:ok, mode, deadline} <- validate_activation(data) do
      Ops.transaction(fn ->
        # Policy lock: exclusive against in-flight refill admission.
        Availability.lock_policy()

        unless Ash.get!(Configuration, id, not_found_error?: false),
          do: Ops.reject("conflict", "Save a fleet loadout before activating it")

        change(id, mode, deadline)
      end)
      |> wake_after()
    end
  end

  def deactivate(id, capability, data) do
    with :ok <- authority(capability),
         :ok <- fleet_id(id),
         true <- data == %{} || {:error, "invalid_input", "Deactivation takes no fields"} do
      Ops.transaction(fn ->
        Availability.lock_policy()
        change(id, "inactive", nil)
      end)
    end
  end

  defp change(id, mode, deadline) do
    prior = Ash.get!(Activation, id, not_found_error?: false)
    deadline = deadline || if(prior, do: prior.claim_deadline_seconds, else: @default_deadline)

    if (is_nil(prior) and mode == "inactive") or
         (prior && prior.mode == mode && prior.claim_deadline_seconds == deadline) do
      %{"activation" => activation(prior, id), "changed" => false}
    else
      stamp = Ops.now()

      activated_at =
        cond do
          mode == "inactive" -> nil
          prior && prior.activated_at -> prior.activated_at
          true -> stamp
        end

      attrs = %{
        mode: mode,
        claim_deadline_seconds: deadline,
        changed_by: @captain["agent"],
        activated_at: activated_at,
        updated_at: stamp
      }

      row =
        if prior,
          do:
            Ops.update(
              prior,
              :change,
              Map.put(attrs, :revision, prior.revision + 1),
              @captain,
              prior.revision
            ),
          else:
            Ops.create(
              Activation,
              :activate,
              Map.merge(attrs, %{fleet_id: id, revision: 1}),
              @captain
            )

      %{"activation" => activation(row, id), "changed" => true}
    end
  end

  defp wake_after({:ok, %{"activation" => %{"mode" => mode}}} = ok) when mode != "inactive" do
    wake()
    ok
  end

  defp wake_after(result), do: result

  def activation(nil, id),
    do: %{
      "fleet_id" => id,
      "mode" => "inactive",
      "claim_deadline_seconds" => @default_deadline,
      "revision" => 0,
      "changed_by" => nil,
      "activated_at" => nil,
      "updated_at" => nil,
      "refill_enabled" => enabled?()
    }

  def activation(row, _id), do: row |> Ops.public() |> Map.put("refill_enabled", enabled?())

  def mode(id) do
    case Ash.get!(Activation, id, not_found_error?: false) do
      nil -> "inactive"
      row -> row.mode
    end
  end

  defp validate_activation(data) when is_map(data) do
    deadline = data["claim_deadline_seconds"]

    if Enum.all?(Map.keys(data), &(&1 in ~w(mode claim_deadline_seconds))) and
         data["mode"] in ~w(dry_run live) and
         (is_nil(deadline) or (is_integer(deadline) and deadline in 60..86_400)),
       do: {:ok, data["mode"], deadline},
       else: invalid_activation()
  end

  defp validate_activation(_), do: invalid_activation()

  defp invalid_activation,
    do:
      {:error, "invalid_input",
       "Activation requires mode dry_run or live and optional integer claim_deadline_seconds from 60 to 86400; unknown fields are forbidden"}

  ## Status

  def status(id, capability) do
    with :ok <- authority(capability), :ok <- fleet_id(id) do
      Ops.transaction(fn ->
        pass = Ash.get!(Pass, id, not_found_error?: false)

        pending =
          Assignment
          |> Ash.Query.filter(fleet_id == ^id and state == "assigned")
          |> Ash.Query.sort(deadline_at: :asc, id: :asc)
          |> Ash.Query.limit(100)
          |> Ash.read!()

        %{rows: misses} =
          Repo.statement!(
            "SELECT agent_id, count(*), max(resolved_at) FROM fleet_refill_assignments WHERE fleet_id=$1 AND state='missed' GROUP BY agent_id ORDER BY count(*) DESC, agent_id LIMIT 100",
            [id]
          )

        %{
          "refill" => %{
            "fleet_id" => id,
            "refill_enabled" => enabled?(),
            "activation" => activation(Ash.get!(Activation, id, not_found_error?: false), id),
            "last_pass" =>
              pass &&
                %{
                  "mode" => pass.mode,
                  "pairs" => pass.pairs,
                  "returned" => pass.returned,
                  "passed_at" => DateTime.to_iso8601(pass.passed_at)
                },
            "pending" =>
              Enum.map(pending, fn row ->
                %{
                  "task_id" => row.task_id,
                  "agent_id" => row.agent_id,
                  "task_revision" => row.task_revision,
                  "message_id" => row.message_id,
                  "deadline_at" => DateTime.to_iso8601(row.deadline_at),
                  "created_at" => DateTime.to_iso8601(row.created_at)
                }
              end),
            "misses" =>
              Enum.map(misses, fn [agent, count, last] ->
                %{
                  "agent_id" => agent,
                  "count" => count,
                  "last_missed_at" => DateTime.to_iso8601(last),
                  "attention" => count >= 2
                }
              end)
          }
        }
      end)
    end
  end

  ## Wake triggers

  # Called inside the task mutation transaction: the job commits with the event.
  def wake(action, data) do
    if action in ~w(release handoff) or
         (action == "update" and is_map(data) and data["status"] == "done"),
       do: wake()

    :ok
  end

  def wake, do: if(enabled?(), do: Wake.enqueue())

  ## Refill pass

  def run_all do
    if enabled?() do
      fleets =
        Activation
        |> Ash.Query.filter(mode in ["dry_run", "live"])
        |> Ash.Query.sort(fleet_id: :asc)
        |> Ash.read!()

      passes =
        Map.new(fleets, fn row ->
          case run_fleet(row.fleet_id) do
            {:ok, pass} -> {row.fleet_id, pass}
            {:error, code, _message} -> {row.fleet_id, %{"error" => code}}
          end
        end)

      {:ok, %{"enabled" => true, "fleets" => passes}}
    else
      {:ok, %{"enabled" => false}}
    end
  end

  # Each card is its own transaction, so a crash keeps every committed
  # assignment and order and the next pass reselects only what is still open.
  def run_fleet(id) do
    with {:ok, plan} when not is_nil(plan) <- Ops.transaction(fn -> plan(id) end) do
      pairs = assign_pass(plan)
      returned = if plan.mode == "live", do: return_expired(plan), else: 0
      record_pass(plan, pairs, returned)
    else
      {:ok, nil} -> {:ok, %{"skipped" => true}}
      error -> error
    end
  end

  defp plan(id) do
    activation = Ash.get!(Activation, id, not_found_error?: false)
    loadout = Ash.get!(Configuration, id, not_found_error?: false)

    if activation && activation.mode in ~w(dry_run live) && loadout do
      agents = loadout.configuration["seats"] |> Enum.map(& &1["agent_id"]) |> Enum.sort()

      repos =
        agents
        |> Enum.flat_map(fn agent ->
          case SeatScope.get(agent) do
            nil -> []
            scope -> scope.allowed_repos
          end
        end)
        |> Enum.uniq()
        |> Enum.sort()

      %{
        fleet_id: id,
        mode: activation.mode,
        deadline: activation.claim_deadline_seconds,
        agents: agents,
        repos: repos,
        cards: backlog(repos)
      }
    end
  end

  # Unassigned open cards in the fleet's repositories: priority (lower number
  # first), then creation time, then ID.
  defp backlog([]), do: []

  defp backlog(repos) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT t.id FROM tasks t
        WHERE t.status='open' AND t.assignee_id IS NULL AND lower(t.repo) = ANY($1)
          AND NOT EXISTS(SELECT 1 FROM task_archives x WHERE x.id=t.id AND x.archived_at IS NOT NULL)
        ORDER BY t.priority ASC, t.created_at ASC, t.id ASC
        LIMIT $2
        """,
        [repos, @card_limit]
      )

    Enum.map(rows, &hd/1)
  end

  defp backlog?(task, repos) do
    task && task.status == "open" && is_nil(task.assignee_id) &&
      SeatScope.canonical_repo(task.repo) in repos &&
      match?(
        %{rows: [[false]]},
        Repo.statement!(
          "SELECT EXISTS(SELECT 1 FROM task_archives WHERE id=$1 AND archived_at IS NOT NULL)",
          [task.id]
        )
      )
  end

  # At most one new card per seat per pass; seats fill to the queue limit over
  # several passes.
  defp assign_pass(plan) do
    {pairs, _used} =
      Enum.reduce_while(plan.cards, {[], []}, fn task_id, {pairs, used} ->
        if length(used) >= length(plan.agents) do
          {:halt, {pairs, used}}
        else
          case Ops.transaction(fn -> assign_card(plan, task_id, used) end) do
            {:ok, %{"agent_id" => agent} = pair} -> {:cont, {[pair | pairs], [agent | used]}}
            _ -> {:cont, {pairs, used}}
          end
        end
      end)

    Enum.reverse(pairs)
  end

  defp assign_card(plan, task_id, used) do
    # Admission prefix first, then the seat gate (inside select), then the task.
    Availability.lock_admission()
    task = Ash.get!(Task, task_id, not_found_error?: false)

    if mode(plan.fleet_id) == plan.mode and backlog?(task, plan.repos) do
      only = Enum.filter(plan.agents, &restricted_match?(SeatScope.get(&1), task))
      candidate = only != [] && Eligibility.select(task, used, only: only)

      cond do
        !candidate ->
          nil

        plan.mode == "dry_run" ->
          pair(task, candidate)

        true ->
          Ops.lock_task(task_id)
          task = Ash.get!(Task, task_id)

          if backlog?(task, plan.repos) and
               restricted_match?(SeatScope.get(candidate.agent_id), task),
             do: assign!(plan, task, candidate)
      end
    end
  end

  defp restricted_match?(nil, _task), do: false

  defp restricted_match?(scope, task) do
    carried = scope.required_labels ++ scope.allowed_labels

    task.labels
    |> Enum.filter(&(&1 in restricted_labels()))
    |> Enum.all?(&(&1 in carried))
  end

  # Existing assign transition and admission, one task_order, one assignment
  # row. All commit together; the row key fences a duplicate order.
  defp assign!(plan, task, candidate) do
    stamp = Ops.now()
    to = candidate.agent_id
    deadline_at = DateTime.add(stamp, plan.deadline, :second)

    data = %{
      "to" => to,
      "note" =>
        "Fleet #{plan.fleet_id} refill assignment; claim by #{DateTime.to_iso8601(deadline_at)} or it returns to the backlog."
    }

    attrs =
      task
      |> Transition.attributes("assign", @system["agent"], data, stamp)
      |> Map.merge(Availability.admit(task, "assign", @system, data))

    result = Ops.apply_system(task, "assign", @system, attrs, data, stamp)
    revision = result["task"]["revision"]

    message =
      Ops.send_message(
        @system,
        %{
          "to" => to,
          "task" => task.id,
          "kind" => "task_order",
          "body" => order(plan, task, deadline_at)
        },
        stamp
      )

    Ops.create(
      Assignment,
      :record,
      %{
        id: digest([task.id, revision]),
        fleet_id: plan.fleet_id,
        task_id: task.id,
        agent_id: to,
        task_revision: revision,
        message_id: message.id,
        event_id: result["event_id"],
        state: "assigned",
        deadline_at: deadline_at,
        created_at: stamp
      },
      @system
    )

    pair(task, candidate)
  end

  defp order(plan, task, deadline_at) do
    title = String.slice(task.title, 0, 200)
    issue = if task.issue_url, do: " Issue: #{task.issue_url}.", else: ""

    "Fleet #{plan.fleet_id} refill assigned #{task.id} (#{task.repo}, priority #{task.priority}): #{title}.#{issue} " <>
      "Claim it with `agentboard task claim #{task.id}` by #{DateTime.to_iso8601(deadline_at)}; " <>
      "unclaimed, it returns to the backlog."
  end

  defp pair(task, candidate),
    do: %{
      "task_id" => task.id,
      "agent_id" => candidate.agent_id,
      "priority" => task.priority,
      "queue_count" => candidate.queue_count
    }

  ## Claim deadline

  defp return_expired(plan) do
    Assignment
    |> Ash.Query.filter(fleet_id == ^plan.fleet_id and state == "assigned")
    |> Ash.Query.sort(deadline_at: :asc, id: :asc)
    |> Ash.Query.limit(500)
    |> Ash.read!()
    |> Enum.count(fn row ->
      match?({:ok, true}, Ops.transaction(fn -> resolve(plan, row) end))
    end)
  end

  defp resolve(plan, initial) do
    Availability.lock_admission()
    Ops.lock_task(initial.task_id)

    Repo.statement!("SELECT id FROM fleet_refill_assignments WHERE id=$1 FOR UPDATE", [
      initial.id
    ])

    row = Ash.get!(Assignment, initial.id)
    task = Ash.get!(Task, row.task_id)
    stamp = Ops.now()

    %{rows: [[newer]]} =
      Repo.statement!(
        "SELECT EXISTS(SELECT 1 FROM fleet_refill_assignments WHERE task_id=$1 AND task_revision>$2)",
        [row.task_id, row.task_revision]
      )

    pending? =
      not newer and task.status == "assigned" and task.assignee_id == row.agent_id and
        task.assigner_id == @system["agent"]

    cond do
      row.state != "assigned" or mode(plan.fleet_id) != "live" ->
        false

      pending? ->
        if DateTime.compare(stamp, row.deadline_at) != :lt and
             not Decisions.held?(task.id, task.assignee_id),
           do: miss!(plan, row, task, stamp),
           else: false

      not newer and task.assignee_id == row.agent_id and
          task.status in ~w(in_progress blocked review done) ->
        close(row, "claimed", stamp)

      true ->
        close(row, "superseded", stamp)
    end
  end

  defp miss!(plan, row, task, stamp) do
    attrs = %{
      status: "open",
      assignee_id: nil,
      assigner_id: nil,
      assignment_authorized: false,
      claimed_at: nil,
      claim_expires_at: nil,
      revision: task.revision + 1,
      updated_at: stamp
    }

    seconds = DateTime.diff(row.deadline_at, row.created_at, :second)

    data = %{
      "note" =>
        "Returned to the backlog: #{row.agent_id} did not claim it within fleet #{plan.fleet_id}'s #{seconds}s claim deadline."
    }

    result = Ops.apply_system(task, "release", @system, attrs, data, stamp)

    Ops.update(
      row,
      :resolve,
      %{state: "missed", resolved_at: stamp, resolution_event_id: result["event_id"]},
      @system
    )

    true
  end

  defp close(row, state, stamp) do
    Ops.update(row, :resolve, %{state: state, resolved_at: stamp}, @system)
    false
  end

  defp record_pass(plan, pairs, returned) do
    Ops.transaction(fn ->
      Repo.statement!("SELECT fleet_id FROM fleet_refill_passes WHERE fleet_id=$1 FOR UPDATE", [
        plan.fleet_id
      ])

      attrs = %{mode: plan.mode, pairs: pairs, returned: returned, passed_at: Ops.now()}

      case Ash.get!(Pass, plan.fleet_id, not_found_error?: false) do
        nil -> Ops.create(Pass, :record, Map.put(attrs, :fleet_id, plan.fleet_id), @system)
        pass -> Ops.update(pass, :replace, attrs, @system)
      end

      %{"mode" => plan.mode, "pairs" => pairs, "returned" => returned}
    end)
  end

  ## Shared guards

  defp digest(parts),
    do: :crypto.hash(:sha256, Jason.encode!(parts)) |> Base.encode16(case: :lower)

  defp authority(capability),
    do:
      if(Captain.authorized?(capability),
        do: :ok,
        else: {:error, "forbidden", "Verified captain capability required"}
      )

  defp fleet_id(id),
    do:
      if(is_binary(id) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/, id),
        do: :ok,
        else: {:error, "invalid_input", "Valid fleet ID required"}
      )
end
