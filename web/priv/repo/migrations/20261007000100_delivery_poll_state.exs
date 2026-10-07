defmodule Agentboard.Repo.Migrations.DeliveryPollState do
  use Ecto.Migration

  def up do
    create table(:delivery_poll_states, primary_key: false) do
      add(:id, references(:delivery_pull_requests, type: :text, on_delete: :restrict),
        primary_key: true
      )

      add(:registered_at, :timestamptz, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:next_poll_at, :timestamptz, null: false)
      add(:generation, :bigint, null: false, default: 0)
      add(:attempt_id, :uuid)
      add(:lease_expires_at, :timestamptz)
      add(:last_attempt_at, :timestamptz)
      add(:last_error, :text)
      add(:ci_state, :text, null: false, default: "unknown")
      add(:observed_at, :timestamptz)
      add(:head_sha, :text)
    end

    create(index(:delivery_poll_states, [:next_poll_at, :id], where: "enabled"))
    create(constraint(:delivery_poll_states, :valid_generation, check: "generation >= 0"))

    create(
      constraint(:delivery_poll_states, :reservation_pair,
        check:
          "(attempt_id IS NULL AND lease_expires_at IS NULL) OR (attempt_id IS NOT NULL AND lease_expires_at IS NOT NULL AND generation > 0 AND last_attempt_at IS NOT NULL)"
      )
    )

    create(
      constraint(:delivery_poll_states, :ci_state,
        check:
          "ci_state IN ('unknown','pending','passing','failing','stale') AND (ci_state NOT IN ('passing','failing') OR (head_sha IS NOT NULL AND observed_at IS NOT NULL))"
      )
    )

    create table(:delivery_poll_states_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:delivery_poll_states, type: :text, on_delete: :restrict), null: false)

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:delivery_poll_states_versions, [:version_source_id, :version_inserted_at]))

    execute(
      "CREATE TRIGGER delivery_poll_states_no_delete BEFORE DELETE ON delivery_poll_states FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER delivery_poll_states_no_truncate BEFORE TRUNCATE ON delivery_poll_states FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER delivery_poll_states_versions_immutable BEFORE UPDATE OR DELETE ON delivery_poll_states_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER delivery_poll_states_versions_no_truncate BEFORE TRUNCATE ON delivery_poll_states_versions FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    # Explicit baseline cutoff: old inventory starts due and unknown, with no
    # fabricated historical observation, head, generation or runtime audit.
    execute(
      "INSERT INTO delivery_poll_states(id,registered_at,next_poll_at) SELECT id,transaction_timestamp(),transaction_timestamp() FROM delivery_pull_requests"
    )

    execute("UPDATE board_schema SET version=8 WHERE id=1")
  end

  def down,
    do: raise("Preserve polling and submission history; roll back a schema-compatible image")
end
