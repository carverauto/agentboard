defmodule Agentboard.DecisionPolicy.Runner do
  @moduledoc "Generated AshOban worker scheduled only by the committed creation transaction."
  use Ash.Resource,
    domain: Agentboard.Board,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  # AshOban's generic-action worker requires a schedule declaration. Application
  # always removes this entry from Cron; only enqueue/2 schedules exact snapshots.
  oban do
    scheduled_actions do
      schedule :apply_created, "0 0 1 1 *" do
        action(:apply)
        queue(:decision_policy)
        max_attempts(5)
        worker_module_name(Agentboard.DecisionPolicy.ApplyCreated)
        default_actor(%{decision_policy_internal: true})
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:decision_policy_internal, true))
    end
  end

  actions do
    action :apply, :map do
      argument(:snapshot, :map, allow_nil?: false)

      run(fn input, _ ->
        case Agentboard.DecisionPolicy.apply_job(input.arguments.snapshot) do
          {:ok, result} -> {:ok, result}
          {:error, code, message} -> {:error, code <> ": " <> message}
        end
      end)
    end
  end
end
