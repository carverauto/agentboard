defmodule Agentboard.DecisionPolicy.Approval do
  @moduledoc "Server decision policy approval; writes use a verified domain boundary."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("decision_policy_approvals")
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
      accept([:id, :sha256, :approved_by, :approved_at])
    end
  end

  attributes do
    attribute(:id, :uuid, allow_nil?: false, primary_key?: true)
    attribute(:sha256, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:approved_by, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:approved_at, :utc_datetime_usec, allow_nil?: false)
  end
end
