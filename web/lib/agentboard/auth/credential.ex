defmodule Agentboard.Auth.Credential do
  @moduledoc "Hash-only board credentials; never use Operations.public/1 on this resource."
  use Ash.Resource, domain: Agentboard.Auth, data_layer: AshPostgres.DataLayer

  postgres do
    table("agent_api_credentials")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :issue do
      accept([
        :id,
        :agent_id,
        :token_hash,
        :fingerprint,
        :scope,
        :channel_ids,
        :issuer,
        :created_at
      ])
    end

    update :revoke do
      accept([:revoked_at])
    end

    update :use do
      accept([:last_used_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:agent_id, :string, allow_nil?: false)
    attribute(:token_hash, :string, allow_nil?: false, sensitive?: true)
    attribute(:fingerprint, :string, allow_nil?: false)
    attribute(:scope, :string, allow_nil?: false)
    attribute(:channel_ids, {:array, :string}, allow_nil?: false, default: [])
    attribute(:issuer, :string, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:last_used_at, :utc_datetime_usec)
    attribute(:revoked_at, :utc_datetime_usec)
  end

  identities do
    identity(:credential_hash, [:token_hash])
  end
end
