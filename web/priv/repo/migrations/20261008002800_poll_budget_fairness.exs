defmodule Agentboard.Repo.Migrations.PollBudgetFairness do
  use Ecto.Migration

  def up do
    alter table(:delivery_poll_states) do
      add(:budget_deferred_at, :timestamptz)
      add(:unchanged_polls, :bigint, null: false, default: 0)
      add(:check_fingerprint, :text)
      add(:github_cache, :map, null: false, default: %{})
    end

    create table(:delivery_poll_credits, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :pull_request_id,
        references(:delivery_pull_requests, type: :text, on_delete: :restrict), null: false)

      add(:remaining, :integer, null: false)
      add(:window_end, :timestamptz, null: false)
      add(:expires_at, :timestamptz, null: false)
    end

    create(
      constraint(:delivery_poll_credits, :poll_credit_bound, check: "remaining BETWEEN 0 AND 32")
    )

    create(
      constraint(:delivery_poll_states, :poll_backoff_bound,
        check: "unchanged_polls BETWEEN 0 AND 2"
      )
    )

    create(index(:delivery_poll_credits, [:expires_at]))
    create(index(:delivery_poll_states, [:observed_at, :next_poll_at, :id], where: "enabled"))
    execute("UPDATE board_schema SET version=GREATEST(version,28) WHERE id=1")
  end

  def down do
    raise "Retain polling bookkeeping; disable PR observation instead"
  end
end
