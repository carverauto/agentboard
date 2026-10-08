defmodule Agentboard.Repo.Migrations.MattermostPhase1SharedBot do
  @moduledoc "Phase 1 shared-bot rework: drop the per-agent identity registry; the coverage ledger remains."
  use Ecto.Migration

  def up do
    drop_if_exists table(:conversation_identities_versions)
    drop_if_exists table(:conversation_identities)
  end

  def down, do: raise("Retain conversation coverage evidence; roll back a schema-compatible image")
end
