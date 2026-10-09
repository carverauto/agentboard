defmodule Agentboard.Delivery.ConflictSource do
  @moduledoc "Immutable Event-to-order relation and optional canonical inbox identity."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("delivery_conflict_sources")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :order_id,
        :order_revision,
        :source_key,
        :message_id,
        :message_version,
        :disposition,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:order_id, :uuid, allow_nil?: false)
    attribute(:order_revision, :integer, allow_nil?: false)
    attribute(:source_key, :string, allow_nil?: false)
    attribute(:message_id, :integer)
    attribute(:message_version, :string)
    attribute(:disposition, :string, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
