defmodule Agentboard.Delivery.ConflictDeadlineAudit do
  @moduledoc "Audit-only deadline selection on an existing current order."
  alias Agentboard.Delivery.ConflictEvaluation
  alias Agentboard.Eligibility

  # Routing owns exactly the apply-mode admission/currentness prefix. This
  # records its selected candidate without claiming, handing off or escalating.
  def record(order, evidence, candidate, reason) do
    ConflictEvaluation.record(order.pull_request_id, order.snapshot_id, evidence.stamp, %{
      phase: "deadline",
      mode: "dry_run",
      plan: if(candidate, do: "reassign_repair", else: "escalate_no_eligible_seat"),
      reason: reason,
      current_order_id: order.id,
      current_order_revision: order.revision,
      episode_id: order.episode_id,
      deadline_at: DateTime.to_iso8601(order.deadline_at),
      repair_task_id: order.repair_task_id,
      repair_revision: evidence.task.revision,
      author_id: order.author_id,
      recipient_id: order.recipient_id,
      candidate: candidate,
      head_sha: order.observed_head_sha,
      default_ref: order.default_ref,
      default_tip_sha: order.default_tip_sha,
      evaluation_base_ref: order.evaluation_base_ref,
      evaluation_base_sha: order.evaluation_base_sha,
      queue_limit: Eligibility.queue_limit(),
      native_custody: "unsupported"
    })

    false
  end
end
