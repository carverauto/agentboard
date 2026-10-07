defmodule Agentboard.Delivery.Discovery do
  @moduledoc "Durable, bounded inventory reconciliation; no provider calls or CI verdicts."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    scheduled_actions do
      schedule :reconcile_links, "* * * * *" do
        action(:reconcile)
        queue(:delivery_discovery)
        max_attempts(5)
        worker_module_name(Agentboard.Delivery.ReconcileLinks)
        default_actor(%{role: :system, id: "delivery-discovery"})
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
      argument(:after_id, :string, constraints: [trim?: false, allow_empty?: true])
      run(fn input, _context -> reconcile(input.arguments[:after_id]) end)
    end
  end

  defp reconcile(cursor) do
    if Application.get_env(:agentboard, :pr_discovery_enabled, false) do
      discover_page(cursor)
    else
      # Also fence existing jobs if a deployment disables discovery. Queue
      # state and old persisted jobs must not override the runtime switch.
      {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
    end
  end

  defp discover_page(cursor) do
    case Agentboard.Delivery.discover(cursor, 100) do
      {:ok, %{next_cursor: next} = page} ->
        # Enqueue before this page's job can complete. A crash on either side
        # replays an idempotent page; no cursor lives only in process memory.
        if next do
          AshOban.schedule(__MODULE__, :reconcile_links, action_arguments: %{after_id: next})
        end

        {:ok, page}

      {:error, _code, message} ->
        # AshOban raises a failed action into Oban's retry path, never success.
        {:error, message}
    end
  end
end

