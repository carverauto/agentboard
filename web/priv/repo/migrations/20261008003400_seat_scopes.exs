defmodule Agentboard.Repo.Migrations.SeatScopes do
  use Ecto.Migration

  def up do
    create table(:seat_scopes, primary_key: false) do
      add(:agent_id, references(:agents, type: :text, on_delete: :restrict), primary_key: true)
      add(:allowed_repos, {:array, :text}, null: false)
      add(:required_labels, {:array, :text}, null: false)
      add(:allowed_labels, {:array, :text}, null: false)
      add(:revision, :integer, null: false)
      add(:changed_by, :text, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:seat_scopes, :seat_scope_shape,
        check:
          "cardinality(allowed_repos) BETWEEN 1 AND 100 AND cardinality(required_labels) <= 100 AND cardinality(allowed_labels) <= 100 AND array_position(allowed_repos,NULL) IS NULL AND array_position(required_labels,NULL) IS NULL AND array_position(allowed_labels,NULL) IS NULL AND revision > 0"
      )
    )

    create table(:seat_scopes_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:seat_scopes, column: :agent_id, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:seat_scopes_versions, [:version_source_id, :version_inserted_at]))

    execute(
      "CREATE TRIGGER seat_scopes_versions_immutable BEFORE UPDATE OR DELETE ON seat_scopes_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER seat_scopes_versions_no_truncate BEFORE TRUNCATE ON seat_scopes_versions FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,34) WHERE id=1")
  end

  def down, do: raise("Retain captain scope and audit history; use a compatible image")
end
