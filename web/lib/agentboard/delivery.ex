defmodule Agentboard.Delivery do
  @moduledoc "Canonical PR inventory and internal poll reservations, independent of task visibility and current ownership."
  use Ash.Domain, backwards_compatible_interface?: false, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(Agentboard.Delivery.PullRequest)
    resource(Agentboard.Delivery.PublicationBinding)
    resource(Agentboard.Delivery.ConflictOrder)
    resource(Agentboard.Delivery.ConflictSource)
    resource(Agentboard.Delivery.PublicationGrant)
    resource(Agentboard.Delivery.DuplicateFinding)
    resource(Agentboard.Delivery.DuplicateMonitor)
    resource(Agentboard.Delivery.TaskLink)
    resource(Agentboard.Delivery.Discovery)
    resource(Agentboard.Delivery.PollState)
    resource(Agentboard.Delivery.ProviderBudget)
    resource(Agentboard.Delivery.PollCredit)
    resource(Agentboard.Delivery.Observation)
    resource(Agentboard.Delivery.MergeDisposition)
    resource(Agentboard.Delivery.ObligationDisposition)
    resource(Agentboard.Delivery.CISnapshot)
    resource(Agentboard.Delivery.Obligation)
    resource(Agentboard.Delivery.RebaseFollowUp)
    resource(Agentboard.Delivery.BaseWatch)
    resource(Agentboard.Delivery.BaseObservation)
    resource(Agentboard.Delivery.WorkflowRun)
    resource(Agentboard.Delivery.WorkflowHealth)
    resource(Agentboard.Delivery.WorkflowObservation)
  end

  def discover(after_id \\ nil, limit \\ 100),
    do: Agentboard.Delivery.Inventory.discover(after_id, limit)

  defdelegate reserve_due(limit \\ 20), to: Agentboard.Delivery.Polling

  defdelegate defer_poll(id, attempt_id, generation, delay_seconds, reason),
    to: Agentboard.Delivery.Polling
end
