defmodule Agentboard.Repo.Migrations.RosterIdentityRetire do
  use Ecto.Migration

  def up do
    alter table(:agents) do
      add(:kind, :text, null: false, default: "seat")
      add(:retired_at, :timestamptz)
      add(:retired_by, :text)
      add(:retire_reason, :text)
      add(:retire_forced, :boolean, null: false, default: false)
    end

    create(
      constraint(:agents, :agent_kind, check: "kind IN ('seat','human','system','fixture')")
    )

    execute(
      "UPDATE agents SET kind='system' WHERE model='system' AND harness='ash' AND kind='seat'"
    )

    execute("UPDATE agents SET kind='human' WHERE harness='captain' AND kind='seat'")

    create(index(:agents, [:kind], where: "retired_at IS NULL"))

    execute("UPDATE board_schema SET version=GREATEST(version,30) WHERE id=1")
  end

  def down do
    raise "Retain roster identity history; restore visibility instead"
  end
end
