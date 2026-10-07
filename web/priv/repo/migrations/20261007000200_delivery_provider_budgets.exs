defmodule Agentboard.Repo.Migrations.DeliveryProviderBudgets do
  use Ecto.Migration

  def up do
    create table(:delivery_provider_budgets, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:capacity, :integer, null: false)
      add(:remaining, :integer, null: false)
      add(:reset_at, :timestamptz, null: false)
    end

    create(
      constraint(:delivery_provider_budgets, :valid_budget,
        check:
          "id IN ('github','buildbuddy') AND capacity BETWEEN 1 AND 1000 AND remaining BETWEEN 0 AND capacity"
      )
    )

    execute(
      "INSERT INTO delivery_provider_budgets(id,capacity,remaining,reset_at) VALUES ('github',60,60,transaction_timestamp()+interval '60 seconds'),('buildbuddy',30,30,transaction_timestamp()+interval '60 seconds')"
    )

    execute("UPDATE board_schema SET version=9 WHERE id=1")
  end

  def down, do: raise("Retain durable observation budgets; roll back a schema-compatible image")
end
