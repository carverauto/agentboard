defmodule Agentboard.Repo.Migrations.FleetRefill do
  use Ecto.Migration

  # Schema 46: captain fleet activation and deterministic backlog refill.
  # Activation is a separate captain record beside the dormant loadout, whose
  # shape constraint is unchanged. No row is created for an existing fleet, so
  # every fleet stays inactive until a captain activates it.
  def up do
    create table(:fleet_activations, primary_key: false) do
      add(:fleet_id, references(:fleet_loadouts, type: :text, on_delete: :restrict),
        primary_key: true
      )

      add(:mode, :text, null: false)
      add(:claim_deadline_seconds, :integer, null: false)
      add(:revision, :integer, null: false)
      add(:changed_by, :text, null: false)
      add(:activated_at, :timestamptz)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:fleet_activations, :fleet_activation_shape,
        check:
          "mode IN ('inactive','dry_run','live') AND claim_deadline_seconds BETWEEN 60 AND 86400 AND revision > 0 AND (mode = 'inactive') = (activated_at IS NULL)"
      )
    )

    create table(:fleet_activations_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:fleet_activations, column: :fleet_id, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:fleet_activations_versions, [:version_source_id, :version_inserted_at]))

    # One row per refill assignment. The primary key is derived from the task
    # ID and the task revision the assignment produced, so the assignment, its
    # single task_order and this row commit together exactly once.
    create table(:fleet_refill_assignments, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:fleet_id, references(:fleet_loadouts, type: :text, on_delete: :restrict), null: false)
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:agent_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:task_revision, :bigint, null: false)
      add(:message_id, references(:messages, type: :bigint, on_delete: :restrict), null: false)
      add(:event_id, :bigint, null: false)
      add(:state, :text, null: false)
      add(:deadline_at, :timestamptz, null: false)
      add(:created_at, :timestamptz, null: false)
      add(:resolved_at, :timestamptz)
      add(:resolution_event_id, :bigint)
    end

    create(
      constraint(:fleet_refill_assignments, :fleet_refill_assignment_shape,
        check:
          "state IN ('assigned','claimed','missed','superseded') AND task_revision > 0 AND (state = 'assigned') = (resolved_at IS NULL) AND (resolution_event_id IS NULL OR state = 'missed')"
      )
    )

    create(unique_index(:fleet_refill_assignments, [:task_id, :task_revision]))
    create(unique_index(:fleet_refill_assignments, [:message_id]))
    create(index(:fleet_refill_assignments, [:fleet_id, :state, :deadline_at]))
    create(index(:fleet_refill_assignments, [:fleet_id, :agent_id, :state]))

    # Latest pass per fleet: would-assign pairs in dry-run, assigned pairs live.
    create table(:fleet_refill_passes, primary_key: false) do
      add(:fleet_id, references(:fleet_loadouts, type: :text, on_delete: :restrict),
        primary_key: true
      )

      add(:mode, :text, null: false)
      add(:pairs, {:array, :map}, null: false)
      add(:returned, :integer, null: false)
      add(:passed_at, :timestamptz, null: false)
    end

    create(
      constraint(:fleet_refill_passes, :fleet_refill_pass_shape,
        check:
          "mode IN ('dry_run','live') AND cardinality(pairs) <= 32 AND array_position(pairs,NULL) IS NULL AND returned >= 0"
      )
    )

    for table <- ~w(fleet_activations_versions) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    # Reserved server attribution for refill assignments, orders and returns.
    # Like system-decision-policy, a pre-existing row cannot prove its origin.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM agents WHERE id='fleet-refill') THEN
        RAISE EXCEPTION 'Reserved fleet-refill identity conflicts with an existing agent; preserve it and resolve explicitly before migrating';
      END IF;
    END $$
    """)

    execute(
      "INSERT INTO agents(id,name,model,harness,kind,capabilities,metadata,created_at,updated_at) VALUES ('fleet-refill','Fleet refill (server)','system','ash','system','{}','{}',transaction_timestamp(),transaction_timestamp())"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,46) WHERE id=1")
  end

  def down,
    do:
      raise("Retain fleet activation history and refill assignment evidence; use compatible code")
end
