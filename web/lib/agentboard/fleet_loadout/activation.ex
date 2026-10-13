defmodule Agentboard.FleetLoadout.Activation do
  @moduledoc "Captain-owned per-fleet activation (inactive, dry_run or live); absent means inactive."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("fleet_activations")
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

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update]) do
      authorize_if(actor_attribute_equals(:fleet_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :activate do
      accept([
        :fleet_id,
        :mode,
        :claim_deadline_seconds,
        :revision,
        :changed_by,
        :activated_at,
        :updated_at
      ])
    end

    update :change do
      accept([:mode, :claim_deadline_seconds, :revision, :changed_by, :activated_at, :updated_at])
    end
  end

  validations do
    validate(attribute_in(:mode, ~w(inactive dry_run live)))
  end

  attributes do
    attribute(:fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:mode, :string, allow_nil?: false, public?: true)
    attribute(:claim_deadline_seconds, :integer, allow_nil?: false, public?: true)
    attribute(:revision, :integer, allow_nil?: false, constraints: [min: 1], public?: true)
    attribute(:changed_by, :string, allow_nil?: false, public?: true)
    attribute(:activated_at, :utc_datetime_usec, public?: true)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
