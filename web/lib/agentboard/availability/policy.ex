defmodule Agentboard.Availability.Policy do
  @moduledoc "Captain-authored availability selectors; expiry retains an explicit active override."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events, AshOban]

  postgres do
    table("availability_policies")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  oban do
    scheduled_actions do
      schedule :expire_due, "* * * * *" do
        action(:expire_due)
        queue(:housekeeping)
        max_attempts(5)
        worker_module_name(Agentboard.Availability.ExpireDue)
        default_actor(%{availability_admin: true, id: "availability-expiry"})
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update, :action]) do
      authorize_if(actor_attribute_equals(:availability_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :create_policy do
      accept([
        :id,
        :agent_id,
        :harness,
        :model_pattern,
        :state,
        :reason,
        :until,
        :revision,
        :changed_by,
        :updated_at
      ])
    end

    update :set_policy do
      accept([:state, :reason, :until, :revision, :changed_by, :updated_at])
    end

    update :expire do
      accept([:state, :until, :revision, :changed_by, :updated_at])
    end

    action :expire_due, :map do
      run(fn _, _ -> Agentboard.Availability.expire_due() end)
    end
  end

  validations do
    validate(attribute_in(:state, ~w(active reserved out_of_service)))
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:agent_id, :string, public?: true)
    attribute(:harness, :string, constraints: [trim?: false], public?: true)
    attribute(:model_pattern, :string, constraints: [trim?: false], public?: true)
    attribute(:state, :string, allow_nil?: false, public?: true)
    attribute(:reason, :string, public?: true)
    attribute(:until, :utc_datetime_usec, public?: true)
    attribute(:revision, :integer, allow_nil?: false, constraints: [min: 1], public?: true)
    attribute(:changed_by, :string, allow_nil?: false, public?: true)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
