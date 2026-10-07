defmodule Agentboard.Mattermost.Router do
  @moduledoc "Bounded AshOban fan-out independent of CI delivery queues."
  use Ash.Resource,
    domain: Agentboard.Mattermost,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    scheduled_actions do
      schedule :route_pending, "* * * * *" do
        action(:route_pending)
        queue(:mattermost_router)
        max_attempts(5)
        worker_module_name(Agentboard.Mattermost.RoutePending)
        default_actor(%{role: :system, id: "mattermost-bridge"})
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    action :route_pending, :map do
      run(fn _input, _context -> Agentboard.Mattermost.Routing.route() end)
    end

    action :send_intent, :map do
      argument(:id, :string, allow_nil?: false)
      run(fn input, _context -> Agentboard.Mattermost.Delivery.send_intent(input.arguments.id) end)
    end
  end
end
