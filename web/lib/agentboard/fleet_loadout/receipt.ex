defmodule Agentboard.FleetLoadout.Receipt do
  @moduledoc "Captain-owned dormant fleet receipt; never an operational worker resource."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("fleet_loadout_receipts")
    repo(Agentboard.Repo)
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
      accept([:id, :fleet_id, :idempotency_key, :request, :response, :created_at])
    end
  end

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true)
    attribute(:fleet_id, :string, allow_nil?: false)
    attribute(:idempotency_key, :string, allow_nil?: false)
    attribute(:request, :map, allow_nil?: false)
    attribute(:response, :map, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
