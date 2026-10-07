defmodule Agentboard.Cooperation.Scheduler do
  use Ash.Resource,
    domain: Agentboard.Cooperation,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    scheduled_actions do
      schedule :reconcile, "* * * * *" do
        action(:reconcile)
        queue(:cooperation)
        max_attempts(5)
        worker_module_name(Agentboard.Cooperation.Reconcile)
        default_actor(%{role: :system, id: "cooperation"})
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    action :reconcile, :map do
      run(fn _, _ ->
        if Application.get_env(:agentboard, :cooperation_enabled, false) do
          with {:ok, routing} <-
                 Agentboard.Board.Operations.transaction(fn ->
                   Agentboard.Cooperation.Runtime.route()
                 end),
               {:ok, reminders} <- Agentboard.Delivery.Accountability.tick(),
               do: {:ok, Map.merge(routing, reminders)}
        else
          {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
        end
      end)
    end
  end
end
