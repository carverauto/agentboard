defmodule Agentboard.Coordinator.Item do
  @moduledoc "Append-only exact-version handling evidence, not source acknowledgment."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("coordinator_handling_items")
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
        :batch_id,
        :decision_id,
        :source_version,
        :task_id,
        :task_revision,
        :requester_id,
        :disposition,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:batch_id, :uuid, allow_nil?: false)
    attribute(:decision_id, :uuid, allow_nil?: false)

    for name <- [:source_version, :task_id, :requester_id, :disposition] do
      attribute(name, :string, allow_nil?: false, constraints: [trim?: false])
    end

    attribute(:task_revision, :integer, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
