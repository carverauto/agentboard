defmodule Agentboard.Repo.Migrations.CoordinatorHandling do
  use Ecto.Migration

  def up do
    drop(constraint(:agent_api_credentials, :agent_credential_scope))

    create(
      constraint(:agent_api_credentials, :agent_credential_scope,
        check:
          "scope IN ('agent','coordinator','coordinator_participant','coordinator_runner','system','captain-admin')"
      )
    )

    create table(:coordinator_handling_batches, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:actor_id, references(:agents, type: :text, on_delete: :restrict), null: false)

      add(:credential_id, references(:agent_api_credentials, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:operation, :text, null: false)
      add(:retry_key, :text, null: false)
      add(:request_hash, :text, null: false)
      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:item_count, :integer, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:coordinator_handling_batches, [:actor_id, :operation, :retry_key]))

    create(
      constraint(:coordinator_handling_batches, :coordinator_batch_shape,
        check:
          "operation='ack' AND octet_length(retry_key) BETWEEN 1 AND 128 AND request_hash ~ '^[0-9a-f]{64}$' AND item_count BETWEEN 1 AND 20"
      )
    )

    create table(:coordinator_handling_items, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:batch_id, references(:coordinator_handling_batches, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:decision_id, references(:decision_requests, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:source_version, :text, null: false)
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:task_revision, :bigint, null: false)
      add(:requester_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:disposition, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:coordinator_handling_items, [:batch_id, :decision_id]))
    create(index(:coordinator_handling_items, [:decision_id, :source_version, :created_at]))

    create(
      constraint(:coordinator_handling_items, :coordinator_item_shape,
        check:
          "source_version ~ '^[0-9a-f]{64}$' AND task_revision>0 AND disposition IN ('reviewed','escalated','deferred')"
      )
    )

    for table <- ~w(coordinator_handling_batches coordinator_handling_items) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("""
    CREATE FUNCTION board_require_coordinator_batch() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE target uuid; expected integer;
    BEGIN
      IF TG_TABLE_NAME='coordinator_handling_batches' THEN
        target:=NEW.id; expected:=NEW.item_count;
      ELSE
        target:=NEW.batch_id;
        SELECT item_count INTO expected FROM coordinator_handling_batches WHERE id=target;
      END IF;
      IF (SELECT count(*) FROM coordinator_handling_items WHERE batch_id=target) <> expected THEN
        RAISE EXCEPTION 'conflict' USING DETAIL='Handling batch requires all exact members';
      END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER coordinator_batch_members AFTER INSERT ON coordinator_handling_batches DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION board_require_coordinator_batch()"
    )

    execute(
      "CREATE CONSTRAINT TRIGGER coordinator_item_batch AFTER INSERT ON coordinator_handling_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION board_require_coordinator_batch()"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,40) WHERE id=1")
  end

  def down, do: raise("Retain immutable coordinator handling evidence; use compatible code")
end
