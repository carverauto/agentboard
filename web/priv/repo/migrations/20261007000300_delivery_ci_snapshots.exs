defmodule Agentboard.Repo.Migrations.DeliveryCISnapshots do
  use Ecto.Migration

  def up do
    create table(:delivery_ci_snapshots, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :pull_request_id,
        references(:delivery_pull_requests, type: :text, on_delete: :restrict),
        null: false
      )

      add(:generation, :bigint, null: false)
      add(:observed_at, :timestamptz, null: false)
      add(:head_sha, :text, null: false)
      add(:base_sha, :text, null: false)
      add(:lifecycle, :text, null: false)
      add(:ci_state, :text, null: false)
      add(:payload, :map, null: false)
    end

    create(unique_index(:delivery_ci_snapshots, [:pull_request_id, :generation]))

    create(
      constraint(:delivery_ci_snapshots, :valid_observation,
        check:
          "generation>0 AND ci_state IN ('unknown','pending','failing') AND lifecycle IN ('open','closed','merged') AND head_sha ~ '^[0-9a-f]{40}$' AND base_sha ~ '^[0-9a-f]{40}$' AND octet_length(payload::text)<=262144"
      )
    )

    execute(
      "CREATE TRIGGER delivery_ci_snapshots_immutable BEFORE UPDATE OR DELETE ON delivery_ci_snapshots FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER delivery_ci_snapshots_no_truncate BEFORE TRUNCATE ON delivery_ci_snapshots FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    alter table(:delivery_poll_states) do
      add(:base_sha, :text)
      add(:snapshot_id, references(:delivery_ci_snapshots, type: :uuid, on_delete: :restrict))
      add(:lifecycle, :text)
    end

    alter table(:delivery_provider_budgets) do
      add(:blocked_until, :timestamptz)
    end

    execute("UPDATE board_schema SET version=10 WHERE id=1")
  end

  def down,
    do: raise("Retain CI observations; disable polling and roll back a schema-compatible image")
end

