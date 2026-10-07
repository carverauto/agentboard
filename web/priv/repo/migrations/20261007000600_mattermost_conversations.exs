defmodule Agentboard.Repo.Migrations.MattermostConversations do
  @moduledoc "Additive per-channel coverage ledger for Phase 1 shared-bot chat. Version is bumped by 00601 once both land."
  use Ecto.Migration

  def up do
    create table(:conversation_coverage, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:agent_id, :text, null: false)
      add(:channel_id, :text, null: false)
      add(:last_post_id, :text)
      add(:last_version, :integer, null: false, default: 0)
      add(:caught_up, :boolean, null: false, default: false)
      add(:incomplete_reason, :text)
      add(:checked_at, :timestamptz)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:conversation_coverage, :valid_coverage,
        check: "last_version >= 0"
      )
    )

    create(unique_index(:conversation_coverage, [:agent_id, :channel_id], name: :conversation_coverage_agent_id_channel_id_index))

    create table(:conversation_coverage_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:version_source_id, references(:conversation_coverage, type: :uuid, on_delete: :restrict), null: false)
      add(:version_channel_id, :text)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:conversation_coverage_versions, [:version_source_id, :version_inserted_at]))

    execute(
      "CREATE TRIGGER conversation_coverage_versions_immutable BEFORE UPDATE OR DELETE ON conversation_coverage_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER conversation_coverage_versions_no_truncate BEFORE TRUNCATE ON conversation_coverage_versions FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )
  end

  def down, do: raise("Retain conversation coverage evidence; roll back a schema-compatible image")
end
