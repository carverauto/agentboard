defmodule Agentboard.DecisionPolicy.Version do
  @moduledoc "Server decision policy version; writes use a verified domain boundary."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("decision_policy_versions")
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
      accept([:id, :name, :version, :document, :sha256, :created_by, :created_at])
    end
  end

  attributes do
    attribute(:id, :uuid, allow_nil?: false, primary_key?: true)
    attribute(:name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:version, :integer, allow_nil?: false)
    attribute(:document, :map, allow_nil?: false)
    attribute(:sha256, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_by, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
