defmodule Agentboard.Delivery.ConflictDisposition do
  @moduledoc "Persisted conflict deadline and state-change reevaluation through existing AshOban infrastructure."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias Agentboard.Delivery.{ConflictOrder, ConflictPolicy, ConflictRouting, Reconciliation}
  require Ash.Query

  oban do
    scheduled_actions do
      schedule :route_conflicts, "* * * * *" do
        action(:route)
        queue(:delivery_scheduler)
        max_attempts(5)
        worker_module_name(Agentboard.Delivery.RouteConflicts)
        default_actor(%{role: :system, id: "ci-accountability"})
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    action :route, :map do
      argument(:after_id, :uuid)
      argument(:id, :uuid)

      run(fn input, _context ->
        if input.arguments[:id] do
          with {:ok, changed} <- ConflictRouting.route(input.arguments.id),
               do: {:ok, %{changed: changed}}
        else
          reconcile(input.arguments[:after_id])
        end
      end)
    end
  end

  def enqueue(id), do: AshOban.schedule(__MODULE__, :route_conflicts, action_arguments: %{id: id})

  defp reconcile(cursor) do
    if ConflictPolicy.mode() == "apply" do
      Reconciliation.page(
        Ash.Query.filter(ConflictOrder, state == "open"),
        cursor,
        fn next ->
          AshOban.schedule(__MODULE__, :route_conflicts, action_arguments: %{after_id: next})
        end,
        &ConflictRouting.route_locked/1
      )
    else
      {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
    end
  end
end
