defmodule Agentboard.Repo.Migrations.CompletedTaskArchive do
  use Ecto.Migration

  def up do
    Oban.Migrations.up()

    create table(:task_archives, primary_key: false) do
      add(:id, references(:tasks, type: :text, on_delete: :restrict), primary_key: true)
      add(:archived_at, :timestamptz)
      add(:restored_at, :timestamptz)
      add(:revision, :bigint, null: false)
      add(:changed_by, :text, null: false)
    end

    create table(:archive_policy, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:enabled, :boolean, null: false)
      add(:retention_days, :integer, null: false)
      add(:interval_hours, :integer, null: false)
      add(:next_run_at, :timestamptz)
      add(:last_run_at, :timestamptz)
      add(:last_archived_count, :integer, null: false)
      add(:revision, :bigint, null: false)
      add(:changed_by, :text, null: false)
    end

    create(constraint(:task_archives, :archive_revision, check: "revision > 0"))

    create(
      constraint(:archive_policy, :archive_policy_contract,
        check:
          "id='board' AND retention_days BETWEEN 1 AND 3650 AND interval_hours IN (1,24,168) AND revision>0 AND last_archived_count>=0"
      )
    )

    execute(
      "INSERT INTO archive_policy(id,enabled,retention_days,interval_hours,last_archived_count,revision,changed_by) VALUES ('board',false,7,24,0,1,'bootstrap')"
    )

    for {table, source} <- [
          {:task_archives_versions, :task_archives},
          {:archive_policy_versions, :archive_policy}
        ] do
      create table(table, primary_key: false) do
        add(:id, :uuid, primary_key: true)

        add(:version_source_id, references(source, type: :text, on_delete: :restrict),
          null: false
        )

        add(:version_action_type, :text, null: false)
        add(:version_action_name, :text, null: false)
        add(:changes, :map)
        add(:version_inserted_at, :timestamptz, null: false)
        add(:version_updated_at, :timestamptz, null: false)
      end

      create(index(table, [:version_source_id, :version_inserted_at]))
    end

    create table(:housekeeping_events) do
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

    create(index(:housekeeping_events, [:resource, :record_id, :id]))

    for table <- ~w(task_archives_versions archive_policy_versions housekeeping_events) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    # Additive capability: retain canonical schema-4 task inventory and lifecycle.
  end

  def down, do: raise("Preserve archive history; roll back a compatible application image")
end

