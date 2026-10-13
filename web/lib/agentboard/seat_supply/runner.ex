defmodule Agentboard.SeatSupply.Runner do
  @moduledoc "Minute AshOban schedule for seat supply; Application drops it while seat supply is disabled."
  use Ash.Resource,
    domain: Agentboard.Board,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    scheduled_actions do
      schedule :supply_fleets, "* * * * *" do
        action(:supply)
        queue(:seat_supply)
        max_attempts(3)
        worker_module_name(Agentboard.SeatSupply.SupplyFleets)
        default_actor(%{role: :system, id: "seat-supply"})
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    action :supply, :map do
      run(fn _input, _context -> Agentboard.SeatSupply.run_all() end)
    end
  end
end
