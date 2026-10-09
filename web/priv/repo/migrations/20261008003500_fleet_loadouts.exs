defmodule Agentboard.Repo.Migrations.FleetLoadouts do
  use Ecto.Migration

  def up do
    create table(:fleet_loadouts, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:configuration, :map, null: false)
      add(:revision, :integer, null: false)
      add(:changed_by, :text, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:fleet_loadouts, :fleet_loadout_shape,
        check:
          "revision > 0 AND configuration ? 'seats' AND configuration = jsonb_build_object('seats',configuration->'seats') AND jsonb_typeof(configuration->'seats')='array' AND jsonb_array_length(configuration->'seats') <= 32"
      )
    )

    create table(:fleet_seat_bindings, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:fleet_id, references(:fleet_loadouts, type: :text, on_delete: :restrict), null: false)
      add(:seat_id, :text, null: false)
      add(:agent_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:harness, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:fleet_seat_bindings, [:fleet_id, :seat_id]))

    create table(:fleet_loadout_receipts, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:fleet_id, references(:fleet_loadouts, type: :text, on_delete: :restrict), null: false)
      add(:idempotency_key, :text, null: false)
      add(:request, :map, null: false)
      add(:response, :map, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:fleet_loadout_receipts, [:fleet_id, :idempotency_key]))

    create table(:fleet_loadouts_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:version_source_id, references(:fleet_loadouts, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:fleet_loadouts_versions, [:version_source_id, :version_inserted_at]))

    for table <- ~w(fleet_loadouts_versions fleet_seat_bindings fleet_loadout_receipts) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("UPDATE board_schema SET version=GREATEST(version,35) WHERE id=1")
  end

  def down,
    do: raise("Retain desired fleet configuration and immutable history; use a compatible image")
end
