defmodule Agentboard.Cooperation.Receipt do
  use Ash.Resource, domain: Agentboard.Cooperation, data_layer: AshPostgres.DataLayer

  postgres do
    table("cooperation_receipts")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :worker_id,
        :idempotency_key,
        :digest,
        :attempt_id,
        :kind,
        :delivery_ids,
        :model,
        :harness,
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

    attribute(:idempotency_key, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:digest, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:attempt_id, :uuid, allow_nil?: false)
    attribute(:kind, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:delivery_ids, {:array, :string}, allow_nil?: false)
    attribute(:model, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

    attribute(:harness, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
