defmodule Agentboard.Repo.Migrations.PRMergeConflicts do
  @moduledoc "Additive branch reservations and retained rebase evidence. Existing snapshots and attribution are preserved."
  use Ecto.Migration

  def up do
    alter table(:delivery_poll_states) do
      add(:base_ref, :text)
      add(:expected_base_sha, :text)
    end

    create(
      constraint(:delivery_poll_states, :valid_expected_base_sha,
        check: "expected_base_sha IS NULL OR expected_base_sha ~ '^[0-9a-f]{40}$'"
      )
    )

    create(index(:delivery_poll_states, [:base_ref, :id], where: "enabled AND lifecycle='open'"))

    create table(:delivery_base_watches, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:owner, :text, null: false)
      add(:repo, :text, null: false)
      add(:ref, :text, null: false)
      add(:head_sha, :text, null: false)
      add(:next_poll_at, :timestamptz, null: false)
      add(:last_success_at, :timestamptz)
      add(:last_error, :text)
      add(:generation, :bigint, null: false, default: 0)
      add(:attempt_id, :uuid)
      add(:lease_expires_at, :timestamptz)
      add(:revision, :bigint, null: false, default: 0)
      add(:invalidated_revision, :bigint, null: false, default: 0)
    end

    create(unique_index(:delivery_base_watches, [:owner, :repo, :ref]))
    create(index(:delivery_base_watches, [:next_poll_at, :id]))

    create(
      constraint(:delivery_base_watches, :valid_branch_watch,
        check:
          "head_sha ~ '^[0-9a-f]{40}$' AND length(ref) BETWEEN 1 AND 255 AND generation>=0 AND revision>=0 AND invalidated_revision BETWEEN 0 AND revision AND ((attempt_id IS NULL)=(lease_expires_at IS NULL))"
      )
    )

    create table(:delivery_rebase_follow_ups, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :pull_request_id,
        references(:delivery_pull_requests, type: :text, on_delete: :restrict),
        null: false
      )

      add(:head_sha, :text, null: false)
      add(:base_sha, :text, null: false)

      add(:snapshot_id, references(:delivery_ci_snapshots, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:repair_task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:responsible_id, references(:agents, type: :text, on_delete: :restrict))
      add(:created_at, :timestamptz, null: false)
      add(:resolved_at, :timestamptz)

      add(
        :resolution_snapshot_id,
        references(:delivery_ci_snapshots, type: :uuid, on_delete: :restrict)
      )
    end

    create(unique_index(:delivery_rebase_follow_ups, [:pull_request_id, :head_sha]))
    create(unique_index(:delivery_rebase_follow_ups, [:repair_task_id]))
    create(index(:delivery_rebase_follow_ups, [:responsible_id], where: "resolved_at IS NULL"))

    create(
      constraint(:delivery_rebase_follow_ups, :valid_rebase_evidence,
        check:
          "head_sha ~ '^[0-9a-f]{40}$' AND base_sha ~ '^[0-9a-f]{40}$' AND ((resolved_at IS NULL)=(resolution_snapshot_id IS NULL))"
      )
    )

    execute("UPDATE board_schema SET version=14 WHERE id=1")
  end

  def down, do: raise("Retain branch and rebase evidence; roll back a schema-compatible image")
end
