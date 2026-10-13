defmodule Agentboard.Intake.Dispatcher do
  @moduledoc "AshOban entry points for the intake issue outbox. Server code owns the loop; no client keeps it running."
  use Ash.Resource,
    domain: Agentboard.Intake,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    scheduled_actions do
      schedule :dispatch_due, "* * * * *" do
        action(:dispatch_due)
        queue(:intake)
        max_attempts(3)
        worker_module_name(Agentboard.Intake.DispatchDue)
        default_actor(%{role: :system, id: "system-intake"})
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    action :dispatch_due, :map do
      run(fn _input, _context -> Agentboard.Intake.Issues.dispatch_due() end)
    end

    action :create_issue, :map do
      argument(:id, :string, allow_nil?: false)
      run(fn input, _context -> Agentboard.Intake.Issues.process(input.arguments.id) end)
    end
  end
end
