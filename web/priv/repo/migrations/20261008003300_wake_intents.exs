defmodule Agentboard.Repo.Migrations.WakeIntents do
  use Ecto.Migration

  def up do
    create table(:wake_intents, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:recipient_id, :text, null: false)
      add(:repo, :text, null: false)
      add(:reason, :text, null: false)
      add(:source_kind, :text, null: false)
      add(:source_id, :text, null: false)
      add(:source_version, :text, null: false)
      add(:reason_hash, :text, null: false)
      add(:task_id, :text)
      add(:source_ref, :map, null: false)
      add(:cooperation_event_id, :uuid)
      add(:delivery_id, :uuid)
      add(:state, :text, null: false)
      add(:reason_code, :text)
      add(:revision, :integer, null: false)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create table(:wake_attempts, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:intent_id, references(:wake_intents, type: :uuid, on_delete: :restrict), null: false)
      add(:worker_id, :text, null: false)
      add(:host_id, :text, null: false)
      add(:enrollment_revision, :bigint, null: false)
      add(:binding_epoch, :integer, null: false)
      add(:session_id, :text, null: false)
      add(:adapter_generation, :text, null: false)
      add(:cooperation_attempt_id, :uuid, null: false)
      add(:idempotency_key, :text, null: false)
      add(:payload_hash, :text, null: false)
      add(:reservation, :map, null: false)
      add(:state, :text, null: false)
      add(:reason_codes, {:array, :text}, null: false)
      add(:evidence_refs, {:array, :text}, null: false)
      add(:expires_at, :timestamptz, null: false)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(unique_index(:wake_intents, [:reason_hash]))

    create(
      unique_index(
        :wake_intents,
        [:recipient_id, :repo, :reason, :source_kind, :source_id, :source_version],
        name: :wake_occurrence_identity
      )
    )

    create(index(:wake_intents, [:recipient_id, :state, :id]))
    create(unique_index(:wake_attempts, [:worker_id, :idempotency_key]))
    create(unique_index(:wake_attempts, [:cooperation_attempt_id]))
    create(index(:wake_attempts, [:intent_id, :created_at]))

    create(
      constraint(:wake_intents, :wake_intent_state,
        check:
          "state IN ('pending','deferred','reserved','submitted','uncertain','suppressed','handled')"
      )
    )

    create(
      constraint(:wake_intents, :wake_reason,
        check:
          "reason IN ('unread_dm','decision_answered','claim_expiring','idle_assigned','blocker_shipped')"
      )
    )

    create(
      constraint(:wake_intents, :wake_source,
        check:
          "source_kind IN ('board_message','mattermost_post','decision_wake','task_claim','task_assignment','blocker_event')"
      )
    )

    create(
      constraint(:wake_intents, :wake_intent_revision,
        check: "revision > 0 AND reason_hash ~ '^[a-f0-9]{64}$'"
      )
    )

    create(
      constraint(:wake_attempts, :wake_attempt_state,
        check: "state IN ('reserved','submitted','not_submitted','uncertain','handled')"
      )
    )

    create(
      constraint(:wake_attempts, :wake_attempt_fence,
        check: "binding_epoch > 0 AND enrollment_revision > 0 AND payload_hash ~ '^[a-f0-9]{64}$'"
      )
    )

    for table_name <- [:wake_intents, :wake_attempts] do
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

    execute("UPDATE board_schema SET version=GREATEST(version,33) WHERE id=1")
  end

  def down do
    raise "Retain wake intent and attempt evidence; disable dispatch instead"
  end
end
