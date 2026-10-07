defmodule Agentboard.Cooperation.Credential do
  use Ash.Resource, domain: Agentboard.Cooperation, data_layer: AshPostgres.DataLayer

  postgres do
    table("cooperation_credentials")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :worker_id,
        :token_hash,
        :scope,
        :epoch,
        :idempotency_key,
        :revoked_at,
        :created_at
      ])
    end

    update :change do
      accept([
        :worker_id,
        :token_hash,
        :scope,
        :epoch,
        :idempotency_key,
        :revoked_at,
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

    attribute(:token_hash, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:scope, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:epoch, :integer)

    attribute(:idempotency_key, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:revoked_at, :utc_datetime_usec)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
