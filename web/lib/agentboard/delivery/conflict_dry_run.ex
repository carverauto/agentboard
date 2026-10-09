defmodule Agentboard.Delivery.ConflictDryRun do
  @moduledoc "Snapshot and retained-order deadline evidence inside canonical fences. Never creates source effects or publication authority."
  alias Agentboard.Board.Resources.Task

  alias Agentboard.Delivery.{
    ConflictEvaluation,
    ConflictOrder,
    ConflictPolicy,
    PullRequest,
    Rebase
  }

  alias Agentboard.Eligibility
  require Ash.Query

  # Polling owns the sorted base/PR/poll prefix and the audit-log transaction.
  def observe(snapshot, result, stamp) do
    pr = Ash.get!(PullRequest, snapshot.pull_request_id)
    %{links: links, owner: author} = Rebase.source_attribution(pr)

    prior =
      ConflictOrder
      |> Ash.Query.filter(pull_request_id == ^pr.id and state == "open")
      |> Ash.read_one!()

    task = %{
      id: if(prior, do: prior.repair_task_id, else: "dry-run:" <> pr.id),
      repo: pr.owner <> "/" <> pr.repo,
      labels: ["rebase-repair"]
    }

    eligibility = if author, do: Eligibility.admit(author, task)
    repair = if prior, do: Ash.get!(Task, prior.repair_task_id)
    payload = result.payload

    ConflictEvaluation.record(pr.id, snapshot.id, stamp, %{
      phase: "snapshot",
      mode: "dry_run",
      plan: plan(prior, repair, result),
      lifecycle: result.lifecycle,
      mergeable: payload["mergeable"],
      mergeable_state: payload["mergeable_state"],
      head_sha: result.head_sha,
      default_ref: payload["default_ref"],
      default_tip_sha: payload["default_tip_sha"],
      evaluation_base_ref: payload["base_ref"],
      evaluation_base_sha: payload["evaluation_base_sha"],
      source_tasks: Enum.map(links, & &1.task_id),
      author_id: author,
      eligibility: eligibility,
      queue_limit: Eligibility.queue_limit(),
      deadline_seconds: ConflictPolicy.deadline_seconds(),
      current_order_id: if(prior, do: prior.id),
      current_order_revision: if(prior, do: prior.revision),
      native_custody: "unsupported"
    })
  end

  defp plan(prior, repair, result) do
    if Application.get_env(:agentboard, :cooperation_enabled, false) do
      case ConflictPolicy.observation_state(result) do
        :closed -> if(prior, do: "cancel_closed_order", else: "no_open_order")
        :clean -> if(prior, do: "clear_order_without_rebaser_credit", else: "no_conflict")
        :dirty -> dirty_plan(prior, repair, result.payload)
        :unknown -> "unknown_mergeability"
      end
    else
      "cooperation_disabled"
    end
  end

  defp dirty_plan(prior, repair, payload) do
    if Enum.all?(
         ~w(default_ref default_tip_sha base_ref evaluation_base_sha),
         &is_binary(payload[&1])
       ) do
      cond do
        is_nil(prior) -> "create_order"
        same_base?(prior, payload) and prior.recipient_id == repair.assignee_id -> "retain_order"
        true -> "supersede_order"
      end
    else
      "unsupported_base_identity"
    end
  end

  defp same_base?(prior, payload) do
    prior.default_ref == payload["default_ref"] and
      prior.default_tip_sha == payload["default_tip_sha"] and
      prior.evaluation_base_ref == payload["base_ref"] and
      prior.evaluation_base_sha == payload["evaluation_base_sha"]
  end
end
