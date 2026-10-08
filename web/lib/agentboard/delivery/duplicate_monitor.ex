defmodule Agentboard.Delivery.DuplicateMonitor do
  @moduledoc "Bounded replay reconciliation from retained observations, including out-of-order merges."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]
  require Ash.Query

  oban do
    scheduled_actions do
      schedule :reconcile_duplicates, "* * * * *" do
        action(:reconcile)
        queue(:delivery_scheduler)
        max_attempts(5)
        worker_module_name(Agentboard.Delivery.ReconcileDuplicates)
        default_actor(%{role: :system, id: "delivery-duplicates"})
      end
    end
  end
  policies do
    policy action(:reconcile) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end
  actions do
    action :reconcile, :map do
      argument(:after_id, :string)
      run(fn input, _context ->
        if Agentboard.Delivery.Scheduling.enabled?() do
          query = Agentboard.Delivery.PullRequest |> Ash.Query.filter(exists(poll_state, lifecycle == "open"))
          Agentboard.Delivery.Reconciliation.page(query, input.arguments[:after_id], fn next ->
            AshOban.schedule(__MODULE__, :reconcile_duplicates, action_arguments: %{after_id: next})
          end, &Agentboard.Delivery.Duplicates.reconcile/1)
        else
          {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
        end
      end)
    end
  end
end
