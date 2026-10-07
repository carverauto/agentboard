defmodule Agentboard.Repo.Migrations.DeliveryInventory do
  use Ecto.Migration

  def up do
    create table(:delivery_pull_requests, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:owner, :text, null: false)
      add(:repo, :text, null: false)
      add(:number, :text, null: false)
      add(:url, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(
      unique_index(:delivery_pull_requests, [:owner, :repo, :number],
        name: :delivery_pull_requests_github_pr_index
      )
    )

    create(
      constraint(:delivery_pull_requests, :canonical_github_pr,
        check:
          "owner = lower(owner) AND repo = lower(repo) AND number ~ '^[1-9][0-9]*$' AND url = 'https://github.com/' || owner || '/' || repo || '/pull/' || number"
      )
    )

    create table(:delivery_task_links) do
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)

      add(
        :pull_request_id,
        references(:delivery_pull_requests, type: :text, on_delete: :restrict),
        null: false
      )

      add(:submitted_by_id, references(:agents, type: :text, on_delete: :restrict))
      add(:model, :text)
      add(:harness, :text)
      add(:source_event_id, references(:task_events, on_delete: :restrict))
      add(:attribution, :text, null: false)
      add(:linked_at, :timestamptz)
      add(:recorded_at, :timestamptz, null: false)
    end

    create(
      unique_index(:delivery_task_links, [:task_id, :pull_request_id],
        name: :delivery_task_links_task_pr_index
      )
    )

    create(index(:delivery_task_links, [:pull_request_id, :id]))

    create(
      constraint(:delivery_task_links, :submission_provenance,
        check:
          "(attribution IN ('submission','timeline') AND submitted_by_id IS NOT NULL AND model IS NOT NULL AND harness IS NOT NULL AND source_event_id IS NOT NULL AND linked_at IS NOT NULL) OR (attribution = 'unknown' AND submitted_by_id IS NULL AND model IS NULL AND harness IS NULL AND source_event_id IS NULL AND linked_at IS NULL)"
      )
    )

    create table(:delivery_pull_requests_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:delivery_pull_requests, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:delivery_pull_requests_versions, [:version_source_id, :version_inserted_at]))

    for table <- ~w(delivery_pull_requests delivery_task_links delivery_pull_requests_versions) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("UPDATE board_schema SET version=7 WHERE id=1")
  end

  def down,
    do: raise("Preserve PR attribution and audit history; roll back a schema-compatible image")
end

