defmodule Agentboard.Repo.Migrations.MattermostAgentBots do
  @moduledoc "Phase 2 elastic per-agent bots: server-managed bot mapping with encrypted tokens. Stamps schema version 17."
  use Ecto.Migration

  def up do
    create table(:mattermost_agent_bots, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:agent_id, :text, null: false)
      add(:mm_user_id, :text, null: false)
      add(:mm_username, :text, null: false)
      add(:display_name, :text, null: false)
      add(:encrypted_token, :binary)
      add(:state, :text, null: false, default: "pending")
      add(:last_error, :text)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(unique_index(:mattermost_agent_bots, [:agent_id]))
    create(unique_index(:mattermost_agent_bots, [:mm_user_id]))

    create(
      constraint(:mattermost_agent_bots, :agent_bot_state,
        check: "state IN ('pending','active','stale','retired')"
      )
    )

    execute("UPDATE board_schema SET version=17 WHERE id=1")
  end

  def down, do: raise("Retain bot mapping evidence; roll back a schema-compatible image")
end
