defmodule Agentboard.Repo.Migrations.CoordinatorInboxTriage do
  use Ecto.Migration

  def up do
    create table(:coordinator_triage_configuration, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:mode, :text, null: false)
      add(:coordinator_id, references(:agents, type: :text, on_delete: :restrict))
      add(:revision, :integer, null: false)
      add(:changed_by, :text, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:coordinator_triage_configuration, :coordinator_triage_configuration_shape,
        check:
          "id='coordinator' AND mode IN ('off','shadow') AND revision>0 AND (mode='off' OR coordinator_id IS NOT NULL)"
      )
    )

    create table(:coordinator_triage_configuration_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:coordinator_triage_configuration, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(
      index(:coordinator_triage_configuration_versions, [:version_source_id, :version_inserted_at])
    )

    create table(:coordinator_inbox_triage, primary_key: false) do
      add(:message_id, references(:messages, type: :bigint, on_delete: :restrict),
        primary_key: true
      )

      add(:message_created_at, :timestamptz, null: false)
      add(:recipient_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:metadata, :map)
      add(:classification, :text, null: false)
      add(:capture_mode, :text, null: false)
      add(:configuration_revision, :integer, null: false)
      add(:policy_version, :integer, null: false)
      add(:provenance, :map, null: false)
      add(:source_verification, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(
      constraint(:coordinator_inbox_triage, :coordinator_triage_shape,
        check:
          "classification IN ('unclassified','status','ci','conflict','next_work','needs_judgment','captain_addressed') AND capture_mode='shadow' AND configuration_revision>0 AND policy_version=1"
      )
    )

    create(index(:coordinator_inbox_triage, [:recipient_id, :message_created_at, :message_id]))

    create table(:coordinator_triage_dispositions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :message_id,
        references(:coordinator_inbox_triage,
          column: :message_id,
          type: :bigint,
          on_delete: :restrict
        ), null: false)

      add(:sequence, :integer, null: false)
      add(:state, :text, null: false)
      add(:reason_code, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:coordinator_triage_dispositions, [:message_id, :sequence]))

    create(
      constraint(:coordinator_triage_dispositions, :coordinator_triage_disposition_shape,
        check: "sequence>0 AND state IN ('recorded','blocked','escalation_pending')"
      )
    )

    for table <-
          ~w(coordinator_triage_configuration_versions coordinator_inbox_triage coordinator_triage_dispositions) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("""
    CREATE FUNCTION board_require_triage_disposition() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM coordinator_triage_dispositions WHERE message_id=NEW.message_id AND sequence=1) THEN
        RAISE EXCEPTION 'conflict' USING DETAIL='Triage capture requires its initial disposition';
      END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER coordinator_triage_initial_disposition AFTER INSERT ON coordinator_inbox_triage DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION board_require_triage_disposition()"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,36) WHERE id=1")
  end

  def down, do: raise("Retain immutable triage and configuration audit; use a compatible image")
end
