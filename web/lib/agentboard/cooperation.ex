defmodule Agentboard.Cooperation do
  @moduledoc "Scoped durable cooperation; source text and legacy identity headers grant no capabilities."
  use Ash.Domain, backwards_compatible_interface?: false, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(Agentboard.Cooperation.Subscription)
    resource(Agentboard.Cooperation.Binding)
    resource(Agentboard.Cooperation.Credential)
    resource(Agentboard.Cooperation.Event)
    resource(Agentboard.Cooperation.Delivery)
    resource(Agentboard.Cooperation.Batch)
    resource(Agentboard.Cooperation.Attempt)
    resource(Agentboard.Cooperation.Receipt)
    resource(Agentboard.Cooperation.Scheduler)
  end
end
