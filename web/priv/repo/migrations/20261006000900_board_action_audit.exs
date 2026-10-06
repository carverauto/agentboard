defmodule Agentboard.Repo.Migrations.BoardActionAudit do
  use Ecto.Migration

  def up do
    for {table, source, type} <- [
          {:agents_versions, :agents, :text},
          {:tasks_versions, :tasks, :text},
          {:messages_versions, :messages, :bigint}
        ] do
      create table(table, primary_key: false) do
        add(:id, :uuid, primary_key: true)
        add(:version_source_id, references(source, type: type, on_delete: :restrict), null: false)
        add(:version_action_type, :text, null: false)
        add(:version_action_name, :text, null: false)
        add(:changes, :map)
        add(:provenance, :map, null: false)
        add(:version_inserted_at, :timestamptz, null: false)
        add(:version_updated_at, :timestamptz, null: false)
      end

      create(index(table, [:version_source_id, :version_inserted_at]))
    end

    create table(:board_action_events) do
      add(:record_id, :text, null: false)
      add(:version, :integer, null: false)
      add(:occurred_at, :timestamptz, null: false)
      add(:resource, :text, null: false)
      add(:action, :text, null: false)
      add(:action_type, :text, null: false)
      add(:metadata, :map, null: false)
      add(:data, :map, null: false)
      add(:changed_attributes, :map, null: false)
    end

    create(index(:board_action_events, [:resource, :record_id, :id]))

    for table <- ~w(agents_versions tasks_versions messages_versions board_action_events) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("UPDATE board_schema SET version=6 WHERE id=1")
  end

  def down, do: raise("Preserve action/version history; roll back a schema-compatible image")
end

