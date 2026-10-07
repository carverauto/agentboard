defmodule Agentboard.Delivery do
  @moduledoc "Canonical PR inventory and internal poll reservations, independent of task visibility and current ownership."
  use Ash.Domain, backwards_compatible_interface?: false, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(Agentboard.Delivery.PullRequest)
    resource(Agentboard.Delivery.TaskLink)
    resource(Agentboard.Delivery.Discovery)
    resource(Agentboard.Delivery.PollState)
    resource(Agentboard.Delivery.ProviderBudget)
    resource(Agentboard.Delivery.Observation)
  end

  def discover(after_id \\ nil, limit \\ 100),
    do: Agentboard.Delivery.Inventory.discover(after_id, limit)

  defdelegate reserve_due(limit \\ 20), to: Agentboard.Delivery.Polling

  defdelegate defer_poll(id, attempt_id, generation, delay_seconds, reason),
    to: Agentboard.Delivery.Polling
end

