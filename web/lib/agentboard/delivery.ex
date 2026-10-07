defmodule Agentboard.Delivery do
  @moduledoc "Durable canonical PR inventory, independent of task visibility and current ownership."
  use Ash.Domain, backwards_compatible_interface?: false, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(Agentboard.Delivery.PullRequest)
    resource(Agentboard.Delivery.TaskLink)
    resource(Agentboard.Delivery.Discovery)
  end

  def discover(after_id \\ nil, limit \\ 100),
    do: Agentboard.Delivery.Inventory.discover(after_id, limit)
end

