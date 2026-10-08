defmodule Agentboard.Delivery.Observation do
  @moduledoc "Bounded AshOban scheduling independent of task visibility and inventory discovery."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  require Logger

  oban do
    scheduled_actions do
      schedule :schedule_due, "* * * * *" do
        action(:schedule_due)
        queue(:delivery_scheduler)
        max_attempts(5)
        worker_module_name(Agentboard.Delivery.ScheduleDue)
        default_actor(%{role: :system, id: "delivery-observation"})
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    action :schedule_due, :map do
      run(fn _input, _context ->
        result = Agentboard.Delivery.Scheduling.tick()

        try do
          Agentboard.Decisions.cleanup()
        rescue
          e -> Logger.warning("decision cleanup skipped: #{inspect(e.__struct__)}")
        catch
          _, _ -> Logger.warning("decision cleanup skipped")
        end

        result
      end)
    end

    action :poll, :map do
      argument(:id, :string, allow_nil?: false)
      run(fn input, _context -> Agentboard.Delivery.Scheduling.poll(input.arguments.id) end)
    end
  end
end
