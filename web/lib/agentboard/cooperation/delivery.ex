defmodule Agentboard.Cooperation.Delivery do
  use Ash.Resource,
    domain: Agentboard.Cooperation,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("cooperation_deliveries")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([:read])

    create :record do
      accept([:id, :event_id, :worker_id, :state, :received_at, :handled_at, :created_at])
    end

    update :change do
      accept([:event_id, :worker_id, :state, :received_at, :handled_at, :created_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:event_id, :uuid, allow_nil?: false)

    attribute(:worker_id, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:state, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:received_at, :utc_datetime_usec)
    attribute(:handled_at, :utc_datetime_usec)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
