defmodule Agentboard.Repo.Migrations.DuplicateFindings do
  use Ecto.Migration

  def up do
    create table(:delivery_duplicate_findings, primary_key: false) do
      add(:id, references(:delivery_pull_requests, type: :text), primary_key: true)
      add(:merged_pull_request_id, references(:delivery_pull_requests, type: :text), null: false)
      add(:basis, :text, null: false)
      add(:snapshot_id, references(:delivery_ci_snapshots, type: :uuid), null: false)
      add(:merged_snapshot_id, references(:delivery_ci_snapshots, type: :uuid), null: false)
      add(:created_at, :timestamptz, null: false)
      add(:notified_recipients, :map, null: false, default: %{})
    end
    create constraint(:delivery_duplicate_findings, :duplicate_basis, check: "basis IN ('head_branch','task_submission') AND id<>merged_pull_request_id")
    create index(:delivery_ci_snapshots, [:pull_request_id, :lifecycle, :observed_at])
    create index(:delivery_ci_snapshots, ["(payload->>'head_repo')", "(payload->>'head_ref')"], where: "lifecycle='merged'", name: :merged_head_identity)
    execute("UPDATE board_schema SET version=GREATEST(version,24) WHERE id=1")
  end

  def down, do: raise("Retain duplicate evidence; roll back a schema-compatible image")
end
