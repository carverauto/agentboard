defmodule Agentboard.Delivery.BranchFlow.Receipt do
  @moduledoc "Immutable exact settings request/response receipt, committed with its configuration."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("branch_flow_receipts")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(actor_attribute_equals(:branch_flow_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([:id, :configuration_id, :idempotency_key, :request, :response, :created_at])
    end
  end

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true)
    attribute(:configuration_id, :string, allow_nil?: false)
    attribute(:idempotency_key, :string, allow_nil?: false)
    attribute(:request, :map, allow_nil?: false)
    attribute(:response, :map, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
