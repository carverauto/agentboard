defmodule Agentboard.Repo.Migrations.MattermostBridge do
  @moduledoc "Additive outbound lifecycle bridge tables. Board schema stays at 9; no backfill of historical events."
  use Ecto.Migration

  def up do
    create table(:mattermost_outbox, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:source, :text, null: false)
      add(:source_key, :text, null: false)
      add(:source_version, :integer, null: false, default: 1)
      add(:task_id, :text)
      add(:event_id, :bigint)
      add(:destination, :text, null: false)
      add(:routing_revision, :integer, null: false, default: 1)
      add(:state, :text, null: false, default: "pending")
      add(:generation, :integer, null: false, default: 0)
      add(:claim_run_id, :uuid)
      add(:next_eligible_at, :timestamptz, null: false)
      add(:event_marker, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:remote_post_id, :text)
      add(:remote_root_id, :text)
      add(:uncertain_reason, :text)
      add(:last_error, :text)
      add(:attempts, :integer, null: false, default: 0)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(unique_index(:mattermost_outbox, [:source, :source_key], name: :mattermost_outbox_source_uniq))

    create(
      index(:mattermost_outbox, [:state, :next_eligible_at],
        name: :mattermost_outbox_pending_idx
      )
    )

    create(
      constraint(:mattermost_outbox, :valid_outbox_state,
        check:
          "state IN ('pending','claimed','sent','uncertain','failed') AND source_version >= 1 AND routing_revision >= 1 AND generation >= 0 AND attempts >= 0"
      )
    )

    create table(:mattermost_task_threads, primary_key: false) do
      add(:task_id, :text, primary_key: true)
      add(:channel_id, :text, null: false)
      add(:root_post_id, :text)
      add(:expected_marker, :text)
      add(:state, :text, null: false, default: "pending")
      add(:uncertain_reason, :text)
      add(:routing_revision, :integer, null: false, default: 1)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:mattermost_task_threads, :valid_thread_state,
        check: "state IN ('pending','rooted','uncertain') AND routing_revision >= 1"
      )
    )

    create table(:mattermost_outbox_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:version_source_id, references(:mattermost_outbox, type: :uuid, on_delete: :restrict), null: false)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:mattermost_outbox_versions, [:version_source_id, :version_inserted_at]))

    create table(:mattermost_task_threads_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:mattermost_task_threads, column: :task_id, type: :text, on_delete: :restrict), null: false)

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:mattermost_task_threads_versions, [:version_source_id, :version_inserted_at]))

    execute(
      "CREATE TRIGGER mattermost_outbox_versions_immutable BEFORE UPDATE OR DELETE ON mattermost_outbox_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER mattermost_outbox_versions_no_truncate BEFORE TRUNCATE ON mattermost_outbox_versions FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER mattermost_task_threads_versions_immutable BEFORE UPDATE OR DELETE ON mattermost_task_threads_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER mattermost_task_threads_versions_no_truncate BEFORE TRUNCATE ON mattermost_task_threads_versions FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )
  end

  def down, do: raise("Retain bridge outbox evidence; roll back a schema-compatible image")
end
