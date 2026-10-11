defmodule Agentboard.DecisionPolicy.State do
  @moduledoc "Server decision policy state; writes use a verified domain boundary."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("decision_policy_state")
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
      authorize_if(actor_attribute_equals(:decision_policy_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([:id, :active_id, :generation, :updated_at])
    end

    update :replace do
      accept([:active_id, :generation, :updated_at])
    end
  end

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true, constraints: [trim?: false])
    attribute(:active_id, :uuid, allow_nil?: true)
    attribute(:generation, :integer, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
