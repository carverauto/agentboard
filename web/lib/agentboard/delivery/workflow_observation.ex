defmodule Agentboard.Delivery.WorkflowObservation do
  @moduledoc "Observation-gated recovery of durable webhook cues; no repository-history polling."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    scheduled_actions do
      schedule :recover_workflows, "* * * * *" do
        action(:schedule)
        queue(:delivery_scheduler)
        max_attempts(5)
        worker_module_name(Agentboard.Delivery.RecoverWorkflows)
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
    action :schedule, :map do
      run(fn _, _ -> Agentboard.Delivery.WorkflowMonitor.tick() end)
    end
    action :check, :map do
      argument(:id, :string, allow_nil?: false)
      run(fn input, _ -> Agentboard.Delivery.WorkflowMonitor.check(input.arguments.id) end)
    end
  end
end

defmodule Agentboard.Delivery.WorkflowWorker do
  use Oban.Worker,
    queue: :delivery_polling,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}),
    do: Agentboard.Delivery.WorkerAction.run(Agentboard.Delivery.WorkflowObservation, :check, args)
end
