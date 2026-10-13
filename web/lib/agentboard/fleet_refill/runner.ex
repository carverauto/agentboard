defmodule Agentboard.FleetRefill.Runner do
  @moduledoc "Minute AshOban schedule for fleet refill; Application drops it while refill is disabled."
  use Ash.Resource,
    domain: Agentboard.Board,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    scheduled_actions do
      schedule :refill_fleets, "* * * * *" do
        action(:refill)
        queue(:fleet_refill)
        max_attempts(3)
        worker_module_name(Agentboard.FleetRefill.RefillFleets)
        default_actor(%{role: :system, id: "fleet-refill"})
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    action :refill, :map do
      run(fn _input, _context -> Agentboard.FleetRefill.run_all() end)
    end
  end
end
