defmodule Agentboard.Delivery.ConflictRouting do
  @moduledoc "Audited repair-only system routing; selected sources and leases never confer native publication authority."
  alias Agentboard.{Availability, Eligibility, Repo}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Task
  alias Agentboard.Decisions.Request

  alias Agentboard.Delivery.{
    ConflictOrder,
    ConflictOrders,
    ConflictPolicy,
    PollState,
    PullRequest,
    RebaseFollowUp
  }

  require Ash.Query
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}

  def route(id), do: Ops.transaction(fn -> route_locked(id) end)

  # Each AshOban page opens an independent transaction through Reconciliation.
  def route_locked(id) do
    order = Ash.get!(ConflictOrder, id, not_found_error?: false)

    if enabled?() and not is_nil(order) and order.state == "open" do
      evidence = fence(order)
      reason = route_reason(order, evidence.task, evidence.stamp)
      if reason, do: select_and_route(order, evidence, reason), else: false
    else
      false
    end
  end

  defp fence(order) do
    pr = Ash.get!(PullRequest, order.pull_request_id)
    watches = ConflictOrders.lock_evidence(order, pr)
    Availability.lock_admission()

    %{
      pr: pr,
      watches: watches,
      poll: Ash.get!(PollState, pr.id),
      task: Ash.get!(Task, order.repair_task_id),
      stamp: Ops.now()
    }
  end

  defp route_reason(order, task, stamp) do
    recipient = if order.recipient_id, do: Eligibility.admit(order.recipient_id, task)
    author_turn? = not is_nil(order.author_id) and order.recipient_id == order.author_id
    deadline_passed? = DateTime.compare(stamp, order.deadline_at) != :lt

    cond do
      deadline_passed? and author_turn? -> "author_deadline"
      deadline_passed? -> "retained_deadline"
      is_nil(recipient) -> "recipient_ineligible"
      not recipient.eligible -> "recipient_ineligible"
      true -> nil
    end
  end

  defp select_and_route(initial, evidence, reason) do
    excluded = [initial.recipient_id, initial.author_id] |> Enum.reject(&is_nil/1)
    candidate = Eligibility.select(evidence.task, excluded)
    Ops.lock_task(initial.repair_task_id)

    Repo.statement!("SELECT id FROM delivery_conflict_orders WHERE id::text=$1 FOR UPDATE", [
      initial.id
    ])

    order = Ash.get!(ConflictOrder, initial.id)
    task = Ash.get!(Task, initial.repair_task_id)

    if current?(initial, order, task, evidence) do
      execute_plan(order, Map.put(evidence, :task, task), candidate, reason)
    else
      false
    end
  end

  defp execute_plan(order, evidence, candidate, reason) do
    if ConflictPolicy.mode() == "dry_run" do
      Agentboard.Delivery.ConflictDeadlineAudit.record(order, evidence, candidate, reason)
    else
      if candidate do
        replacement =
          ConflictOrders.reassign(
            order,
            evidence.task,
            evidence.pr,
            candidate,
            reason,
            evidence.stamp
          )

        escalate(replacement, "native_custody_unsupported", evidence.stamp)
        true
      else
        escalate(order, "no_eligible_seat", evidence.stamp)
      end
    end
  end

  defp current?(initial, order, task, evidence) do
    follow =
      RebaseFollowUp
      |> Ash.Query.filter(current_order_id == ^order.id and is_nil(resolved_at))
      |> Ash.read_one!()

    poll = evidence.poll

    order.state == "open" and order.revision == initial.revision and not is_nil(follow) and
      task.status not in ~w(done cancelled) and task.assignee_id == initial.recipient_id and
      poll.lifecycle == "open" and poll.head_sha == order.observed_head_sha and
      poll.default_ref == order.default_ref and poll.expected_default_sha == order.default_tip_sha and
      poll.base_ref == order.evaluation_base_ref and
      poll.expected_base_sha == order.evaluation_base_sha and
      evidence.watches[order.default_ref] == order.default_tip_sha and
      evidence.watches[order.evaluation_base_ref] == order.evaluation_base_sha
  end

  defp enabled?,
    do:
      ConflictPolicy.mode() in ~w(apply dry_run) and
        Application.get_env(:agentboard, :cooperation_enabled, false)

  defp escalate(%{escalation_decision_id: id}, _reason, _stamp) when not is_nil(id), do: false

  defp escalate(order, reason, stamp) do
    request =
      Ops.create(
        Request,
        :create,
        %{
          id: Ash.UUID.generate(),
          task_id: order.repair_task_id,
          requester_id: @actor["agent"],
          kind: "blocked_decision",
          gate_ref: "conflict-order:#{order.id}:#{order.revision}:#{reason}",
          question:
            "Conflict repair #{order.repair_task_id}: #{reason}. Captain action required.",
          findings:
            "Order #{order.id}/#{order.revision}. The source claim is unchanged. " <>
              "Native custody and publication are unsupported; no branch-write grant was issued.",
          options: [],
          status: "open",
          created_at: stamp,
          updated_at: stamp
        },
        @actor
      )

    Ops.update(order, :change, %{escalation_decision_id: request.id, updated_at: stamp}, @actor)
    task = Ash.get!(Task, order.repair_task_id)

    Ops.project_event(
      task.id,
      @actor,
      "conflict_escalated",
      reason,
      task.revision,
      task.revision,
      %{decision_id: request.id, order_id: order.id, order_revision: order.revision},
      stamp
    )

    true
  end
end
