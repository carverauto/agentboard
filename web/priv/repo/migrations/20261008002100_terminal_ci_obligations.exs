defmodule Agentboard.Repo.Migrations.TerminalCIObligations do
  use Ecto.Migration

  def up do
    alter table(:delivery_obligations) do
      add(:resolution_reason, :text)

      add(
        :resolution_snapshot_id,
        references(:delivery_ci_snapshots, type: :uuid, on_delete: :restrict)
      )
    end

    execute(
      "UPDATE delivery_obligations SET resolution_reason='legacy' WHERE resolved_at IS NOT NULL"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,21) WHERE id=1")
  end

  def down, do: raise("Preserve obligation disposition evidence; use a schema-compatible image")
end
