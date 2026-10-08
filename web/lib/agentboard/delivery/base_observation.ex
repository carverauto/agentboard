defmodule Agentboard.Delivery.BaseObservation do
  @moduledoc "Minute AshOban admission of bounded branch checks; all I/O uses the shared GitHub budget."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    scheduled_actions do
      schedule :observe_bases, "* * * * *" do
        action(:schedule)
        queue(:delivery_scheduler)
        max_attempts(5)
        worker_module_name(Agentboard.Delivery.ScheduleBases)
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
      run(fn _, _ -> Agentboard.Delivery.BaseMonitor.tick() end)
    end

    action :check, :map do
      argument(:id, :string, allow_nil?: false)
      run(fn input, _ -> Agentboard.Delivery.BaseMonitor.check(input.arguments.id) end)
    end

    action :invalidate, :map do
      argument(:id, :string, allow_nil?: false)
      argument(:revision, :integer, allow_nil?: false)
      argument(:cursor, :string, default: "", constraints: [trim?: false, allow_empty?: true])
      run(fn input, _ -> Agentboard.Delivery.BaseMonitor.invalidate(input.arguments) end)
    end
  end
end

defmodule Agentboard.Delivery.BaseWorker do
  use Oban.Worker,
    queue: :delivery_polling,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}),
    do: Agentboard.Delivery.WorkerAction.run(Agentboard.Delivery.BaseObservation, :check, args)
end

defmodule Agentboard.Delivery.BaseInvalidationWorker do
  use Oban.Worker,
    queue: :delivery_scheduler,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}),
    do:
      Agentboard.Delivery.WorkerAction.run(Agentboard.Delivery.BaseObservation, :invalidate, args)
end
