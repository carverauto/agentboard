defmodule Agentboard.Repo.Migrations.MattermostConversations do
  @moduledoc "Additive worker identity registry and per-channel coverage ledger. Version is bumped by 00601 once both land."
  use Ecto.Migration

  def up do
    create table(:conversation_identities, primary_key: false) do
      add(:agent_id, :text, primary_key: true)
      add(:mm_user_id, :text, null: false)
      add(:mm_username, :text)
      add(:status, :text, null: false, default: "enrolled")
      add(:credential_ref, :text)
      add(:membership_verified_at, :timestamptz)
      add(:last_error, :text)
      add(:routing_revision, :integer, null: false, default: 1)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(unique_index(:conversation_identities, [:mm_user_id], name: :conversation_identities_mm_user_index))

    create(
      constraint(:conversation_identities, :valid_identity_status,
        check: "status IN ('enrolled','suspended','revoked') AND routing_revision >= 1"
      )
    )

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

    create table(:conversation_identities_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:version_source_id, references(:conversation_identities, type: :text, column: :agent_id, on_delete: :restrict), null: false)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:conversation_identities_versions, [:version_source_id, :version_inserted_at]))

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
      "CREATE TRIGGER conversation_identities_versions_immutable BEFORE UPDATE OR DELETE ON conversation_identities_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER conversation_identities_versions_no_truncate BEFORE TRUNCATE ON conversation_identities_versions FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER conversation_coverage_versions_immutable BEFORE UPDATE OR DELETE ON conversation_coverage_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER conversation_coverage_versions_no_truncate BEFORE TRUNCATE ON conversation_coverage_versions FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )
  end

  def down, do: raise("Retain conversation identity evidence; roll back a schema-compatible image")
end
