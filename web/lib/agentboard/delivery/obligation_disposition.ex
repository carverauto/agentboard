defmodule Agentboard.Delivery.ObligationDisposition do
  @moduledoc "Bounded audited closure of terminal CI obligations, independent of cooperation."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias Agentboard.Delivery.Obligation
  alias Agentboard.Delivery.Scheduling
  require Ash.Query

  oban do
    scheduled_actions do
      schedule :reconcile_obligations, "* * * * *" do
        action(:reconcile)
        queue(:delivery_scheduler)
        max_attempts(5)
        worker_module_name(Agentboard.Delivery.ReconcileTerminalObligations)
        default_actor(%{role: :system, id: "delivery-obligation-disposition"})
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
      argument(:after_id, :uuid)
      run(fn input, _context -> reconcile(input.arguments[:after_id]) end)
    end
  end

  defp reconcile(cursor) do
    if Scheduling.enabled?() do
      query =
        Obligation
        |> Ash.Query.filter(is_nil(resolved_at))

      Agentboard.Delivery.Reconciliation.page(
        query,
        cursor,
        fn next ->
          AshOban.schedule(__MODULE__, :reconcile_obligations,
            action_arguments: %{after_id: next}
          )
        end,
        &Agentboard.Delivery.Accountability.reconcile_obligation/1
      )
    else
      {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
    end
  end
end
