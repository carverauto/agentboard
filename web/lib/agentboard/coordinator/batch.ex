defmodule Agentboard.Coordinator.Batch do
  @moduledoc "Immutable identity-scoped handling request and first attribution."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("coordinator_handling_batches")
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
      authorize_if(actor_attribute_equals(:coordinator_internal, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :actor_id,
        :credential_id,
        :operation,
        :retry_key,
        :request_hash,
        :model,
        :harness,
        :item_count,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:credential_id, :uuid, allow_nil?: false)

    for name <- [:actor_id, :operation, :retry_key, :request_hash, :model, :harness] do
      attribute(name, :string, allow_nil?: false, constraints: [trim?: false])
    end

    attribute(:item_count, :integer, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
