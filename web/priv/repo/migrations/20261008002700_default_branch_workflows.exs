defmodule Agentboard.Repo.Migrations.DefaultBranchWorkflows do
  use Ecto.Migration

  def up do
    create table(:delivery_workflow_runs, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:repository, :text, null: false)
      add(:run_id, :text, null: false)
      add(:requested_at, :timestamptz, null: false)
      add(:next_poll_at, :timestamptz, null: false)
      add(:processed_at, :timestamptz)
      add(:observed_at, :timestamptz)
      add(:last_error, :text)
      add(:generation, :bigint, null: false, default: 0)
      add(:lease_expires_at, :timestamptz)
      add(:workflow_id, :text)
      add(:workflow_name, :text)
      add(:branch, :text)
      add(:head_sha, :text)
      add(:run_number, :bigint)
      add(:run_attempt, :bigint)
      add(:conclusion, :text)
      add(:source_url, :text)
      add(:jobs, {:array, :map}, null: false, default: [])
      add(:responsible_id, references(:agents, type: :text))
      add(:source_tasks, {:array, :text}, null: false, default: [])
      add(:message_id, references(:messages))
      add(:failed_at, :timestamptz)
      add(:resolved_at, :timestamptz)
      add(:resolution_run_id, :text)
    end
    create unique_index(:delivery_workflow_runs, [:repository, :run_id])
    create index(:delivery_workflow_runs, [:next_poll_at])
    create index(:delivery_workflow_runs, [:repository, :workflow_id, :branch, :run_number],
      where: "failed_at IS NOT NULL AND resolved_at IS NULL", name: :workflow_unresolved)
    create table(:delivery_workflow_health, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:green_number, :bigint, null: false, default: 0)
      add(:green_attempt, :bigint, null: false, default: 0)
      add(:green_run_id, :text)
    end
    execute("UPDATE board_schema SET version=GREATEST(version,27) WHERE id=1")
  end
  def down, do: raise("Retain default-branch evidence; roll back a schema-compatible image")
end
