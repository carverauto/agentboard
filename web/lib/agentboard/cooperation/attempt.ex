defmodule Agentboard.Cooperation.Attempt do
  use Ash.Resource,
    domain: Agentboard.Cooperation,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("cooperation_attempts")
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
        :batch_id,
        :worker_id,
        :epoch,
        :generation,
        :idempotency_key,
        :status,
        :reason,
        :created_at,
        :updated_at
      ])
    end

    update :change do
      accept([
        :batch_id,
        :worker_id,
        :epoch,
        :generation,
        :idempotency_key,
        :status,
        :reason,
        :created_at,
        :updated_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:batch_id, :uuid, allow_nil?: false)

    attribute(:worker_id, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:epoch, :integer, allow_nil?: false)
    attribute(:generation, :integer, allow_nil?: false)

    attribute(:idempotency_key, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:status, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:reason, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
