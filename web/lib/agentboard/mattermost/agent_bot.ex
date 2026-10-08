defmodule Agentboard.Mattermost.AgentBot do
  @moduledoc """
  Phase 2 elastic per-agent bot mapping. One row per agent id, keyed by
  Mattermost user id. The token attribute is AshCloak-encrypted at rest
  (column `encrypted_token`) and is NEVER decrypted by default: code
  that needs the plaintext loads the `:token` calculation explicitly,
  and `Operations.public/1` must never run on such a loaded record.
  """
  use Ash.Resource,
    domain: Agentboard.Mattermost,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak]

  postgres do
    table("mattermost_agent_bots")
    repo(Agentboard.Repo)
  end

  cloak do
    vault(Agentboard.Vault)
    attributes([:token])
    encrypt_nil?(false)
  end

  actions do
    defaults([:read, :destroy])

    create :open do
      accept([
        :id,
        :agent_id,
        :mm_user_id,
        :mm_username,
        :display_name,
        :token,
        :state,
        :created_at,
        :updated_at
      ])
    end

    update :mark_active do
      accept([:mm_user_id, :mm_username, :display_name, :token, :state, :last_error, :updated_at])
    end

    update :mark_stale do
      accept([:state, :last_error, :updated_at])
    end

    update :retire do
      accept([:state, :token, :last_error, :updated_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:agent_id, :string, allow_nil?: false, public?: true)
    attribute(:mm_user_id, :string, allow_nil?: false, public?: true)
    attribute(:mm_username, :string, allow_nil?: false, public?: true)
    attribute(:display_name, :string, allow_nil?: false, public?: true)
    attribute(:token, :string, allow_nil?: true, public?: false)
    attribute(:state, :string, allow_nil?: false, default: "pending", public?: true)
    attribute(:last_error, :string, allow_nil?: true, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: false)
  end

  identities do
    identity(:bot_agent, [:agent_id])
    identity(:bot_user, [:mm_user_id])
  end
end
