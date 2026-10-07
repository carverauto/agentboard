defmodule Agentboard.Cooperation.Batch do
  use Ash.Resource, domain: Agentboard.Cooperation, data_layer: AshPostgres.DataLayer

  postgres do
    table("cooperation_batches")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :worker_id,
        :epoch,
        :generation,
        :delivery_ids,
        :payload,
        :payload_hash,
        :more,
        :lease_expires_at,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)

    attribute(:worker_id, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:epoch, :integer, allow_nil?: false)
    attribute(:generation, :integer, allow_nil?: false)
    attribute(:delivery_ids, {:array, :string}, allow_nil?: false)

    attribute(:payload, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:payload_hash, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:more, :boolean, allow_nil?: false)
    attribute(:lease_expires_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
