defmodule Agentboard.Repo.Migrations.RecoveryCheckpoint do
  use Ecto.Migration

  def up do
    create table(:recovery_episodes, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:agent_id, :text, null: false)
      add(:host_id, :text, null: false)
      add(:repo, :text, null: false)
      add(:enrollment_revision, :integer, null: false)
      add(:binding_epoch, :integer, null: false)
      add(:session_id, :text, null: false)
      add(:lease_id, :text, null: false)
      add(:last_heartbeat_at, :timestamptz, null: false)
      add(:policy_id, :text, null: false)
      add(:policy_version, :integer, null: false)
      add(:policy_snapshot, :map, null: false)
      add(:task_ids, {:array, :text}, null: false)
      add(:decision_ids, {:array, :uuid}, null: false)
      add(:state, :text, null: false)
      add(:reason, :text, null: false)
      add(:attempt_number, :integer, null: false)
      add(:budget_used, :integer, null: false)
      add(:attempt_id, :uuid)
      add(:attempt_budget_counted, :boolean, null: false)
      add(:reserved_at, :timestamptz)
      add(:deadline_at, :timestamptz)
      add(:next_attempt_at, :timestamptz)
      add(:new_binding_epoch, :integer)
      add(:new_session_id, :text)
      add(:heartbeat_at, :timestamptz)
      add(:isolation_verified, :boolean, null: false)
      add(:canonical_check_in_complete, :boolean, null: false)
      add(:last_host_result, :text)
      add(:reservations_allowed, :boolean, null: false)
      add(:escalation_key, :text)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      unique_index(
        :recovery_episodes,
        [:agent_id, :enrollment_revision, :binding_epoch, :session_id, :last_heartbeat_at],
        name: :recovery_episode_incarnation
      )
    )

    create(index(:recovery_episodes, [:state, :next_attempt_at, :id]))

    create(
      constraint(:recovery_episodes, :recovery_state,
        check:
          "state IN ('detected','reserved','restarting','verifying','recovered','retry_due','uncertain','cancelled','exhausted')"
      )
    )

    create(
      constraint(:recovery_episodes, :recovery_budget,
        check:
          "attempt_number BETWEEN 0 AND 3 AND budget_used BETWEEN 0 AND 3 AND enrollment_revision > 0 AND binding_epoch > 0 AND policy_version > 0"
      )
    )

    create table(:recovery_attempts, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)

      add(:episode_id, references(:recovery_episodes, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:number, :integer, null: false)
      add(:intent_key, :text, null: false)
      add(:status, :text, null: false)
      add(:reason, :text, null: false)
      add(:reserved_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(unique_index(:recovery_attempts, [:episode_id, :number]))
    create(unique_index(:recovery_attempts, [:intent_key]))

    create(
      constraint(:recovery_attempts, :recovery_attempt_number, check: "number BETWEEN 1 AND 3")
    )

    for table_name <- [:recovery_episodes, :recovery_attempts] do
      version_table = :"#{table_name}_versions"

      create table(version_table, primary_key: false) do
        add(:id, :uuid, primary_key: true)
        add(:version_action_type, :text, null: false)
        add(:version_action_name, :text, null: false)

        add(:version_source_id, references(table_name, type: :uuid, on_delete: :restrict),
          null: false
        )

        add(:changes, :map)
        add(:provenance, :map, null: false)
        add(:version_inserted_at, :timestamptz, null: false)
        add(:version_updated_at, :timestamptz, null: false)
      end

      create(index(version_table, [:version_source_id, :version_inserted_at]))

      execute(
        "CREATE TRIGGER #{version_table}_immutable BEFORE UPDATE OR DELETE ON #{version_table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{version_table}_no_truncate BEFORE TRUNCATE ON #{version_table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("UPDATE board_schema SET version=GREATEST(version,31) WHERE id=1")
  end

  def down do
    raise "Retain recovery evidence; disable reservations instead"
  end
end

