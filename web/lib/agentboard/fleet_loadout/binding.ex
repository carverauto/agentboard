defmodule Agentboard.FleetLoadout.Binding do
  @moduledoc "Captain-owned dormant fleet binding; never an operational worker resource."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("fleet_seat_bindings")
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
      accept([:id, :fleet_id, :seat_id, :agent_id, :harness, :created_at])
    end
  end

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true)
    attribute(:fleet_id, :string, allow_nil?: false)
    attribute(:seat_id, :string, allow_nil?: false)
    attribute(:agent_id, :string, allow_nil?: false)
    attribute(:harness, :string, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
