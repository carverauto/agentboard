defmodule Agentboard.Repo.Migrations.SeatSupply do
  use Ecto.Migration

  # Schema 47: server seat-launch intents and enrolled fleet hosts. Captain
  # seat counts default to 0 on every existing activation, so no fleet asks for
  # a seat until a captain sets them, and no host can reserve a launch until a
  # captain enrolls it with a launch cap above 0.
  def up do
    alter table(:fleet_activations) do
      add(:requested_seats, :integer, null: false, default: 0)
      add(:max_seats, :integer, null: false, default: 0)
    end

    create(
      constraint(:fleet_activations, :fleet_activation_seats,
        check: "requested_seats BETWEEN 0 AND 32 AND max_seats BETWEEN 0 AND 32"
      )
    )

    # One row per captain-enrolled host. Only the SHA-256 of the host token is
    # stored; the plaintext is returned once when the captain issues it.
    create table(:fleet_hosts, primary_key: false) do
      add(:host_id, :text, primary_key: true)
      add(:token_hash, :text, null: false)
      add(:launch_cap, :integer, null: false, default: 0)
      add(:revision, :integer, null: false)
      add(:changed_by, :text, null: false)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:fleet_hosts, :fleet_host_shape,
        check:
          "host_id ~ '^[a-z0-9][a-z0-9_-]{0,127}$' AND token_hash ~ '^[0-9a-f]{64}$' AND launch_cap BETWEEN 0 AND 32 AND revision > 0"
      )
    )

    create(unique_index(:fleet_hosts, [:token_hash]))

    # A launch intent names a loadout seat, its identity, harness name and
    # desired host, never a binary, path or argv. Outstanding states occupy the
    # seat; the partial unique index allows at most one per seat.
    create table(:fleet_launch_intents, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:fleet_id, references(:fleet_loadouts, type: :text, on_delete: :restrict), null: false)
      add(:seat_id, :text, null: false)
      add(:agent_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:harness, :text, null: false)
      add(:host_id, :text, null: false)
      add(:loadout_revision, :integer, null: false)
      add(:state, :text, null: false)
      add(:reason, :text)
      add(:workspace_id, :text)
      add(:tab_id, :text)
      add(:pane_id, :text)
      add(:lease_path, :text)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
      add(:reserved_at, :timestamptz)
      add(:launched_at, :timestamptz)
      add(:closed_at, :timestamptz)
    end

    create(
      constraint(:fleet_launch_intents, :fleet_launch_intent_shape,
        check:
          "state IN ('dry_run','pending','reserved','uncertain','launched','failed','expired','superseded','closed','abandoned') AND loadout_revision > 0 AND (state IN ('failed','expired','superseded','closed','abandoned')) = (closed_at IS NOT NULL) AND (state <> 'launched' OR (pane_id IS NOT NULL AND launched_at IS NOT NULL)) AND (state NOT IN ('reserved','uncertain','launched') OR reserved_at IS NOT NULL) AND coalesce(length(reason),0) <= 500"
      )
    )

    create(
      unique_index(:fleet_launch_intents, [:fleet_id, :seat_id],
        name: :fleet_launch_intent_outstanding,
        where: "state IN ('dry_run','pending','reserved','uncertain','launched')"
      )
    )

    create(index(:fleet_launch_intents, [:host_id, :state, :created_at]))
    create(index(:fleet_launch_intents, [:fleet_id, :state, :updated_at]))

    execute("UPDATE board_schema SET version=GREATEST(version,47) WHERE id=1")
  end

  def down,
    do: raise("Retain fleet hosts and launch intent evidence; use compatible code")
end
