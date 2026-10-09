defmodule Agentboard.FleetLoadout.Configuration do
  @moduledoc "Captain-owned dormant fleet configuration; never an operational worker resource."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("fleet_loadouts")
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

    create :record do
      accept([:id, :configuration, :revision, :changed_by, :updated_at])
    end

    update :replace do
      accept([:configuration, :revision, :changed_by, :updated_at])
    end
  end

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true)
    attribute(:configuration, :map, allow_nil?: false)
    attribute(:revision, :integer, allow_nil?: false)
    attribute(:changed_by, :string, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
