defmodule Agentboard.Repo.Migrations.DecisionRequests do
  use Ecto.Migration

  def up do
    create table(:decision_requests, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:requester_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:kind, :text, null: false)
      add(:gate_ref, :text, null: false)
      add(:question, :text, null: false)
      add(:findings, :text, null: false)
      add(:options, {:array, :text}, null: false, default: [])
      add(:status, :text, null: false)
      add(:recommendation, :text)
      add(:recommended_by, :text)
      add(:recommended_at, :timestamptz)
      add(:answer, :text)
      add(:answered_by, :text)
      add(:answered_at, :timestamptz)
      add(:on_behalf_of, :text)
      add(:applied_at, :timestamptz)
      add(:closed_by, :text)
      add(:close_reason, :text)
      add(:closed_at, :timestamptz)
      add(:message_id, references(:messages, type: :bigint, on_delete: :restrict))
      add(:event_id, references(:task_events, type: :bigint, on_delete: :restrict))
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(unique_index(:decision_requests, [:task_id, :gate_ref]))
    create(index(:decision_requests, [:created_at, :id]))
    create(index(:decision_requests, [:requester_id, :created_at, :id]))
    create(index(:decision_requests, [:task_id], where: "status IN ('open','answered')"))

    create(
      constraint(:decision_requests, :decision_kind,
        check: "kind IN ('ask_user_gate','approval','blocked_decision','other')"
      )
    )

    create(
      constraint(:decision_requests, :decision_status,
        check: "status IN ('open','answered','applied','withdrawn','superseded')"
      )
    )

    create(
      constraint(:decision_requests, :decision_bounds,
        check:
          "octet_length(gate_ref) BETWEEN 1 AND 512 AND octet_length(question) BETWEEN 1 AND 8192 AND octet_length(findings) <= 65536 AND cardinality(options) <= 20 AND octet_length(coalesce(answer,'')) <= 8192 AND octet_length(coalesce(recommendation,'')) <= 8192 AND octet_length(coalesce(close_reason,'')) <= 8192"
      )
    )

    create(
      constraint(:decision_requests, :decision_answer,
        check:
          "(answered_at IS NULL AND answer IS NULL AND answered_by IS NULL AND on_behalf_of IS NULL) OR (answered_at IS NOT NULL AND answer IS NOT NULL AND answered_by IS NOT NULL AND on_behalf_of='captain')"
      )
    )

    create(
      constraint(:decision_requests, :decision_applied,
        check: "status <> 'applied' OR (answered_at IS NOT NULL AND applied_at IS NOT NULL)"
      )
    )

    create table(:decision_wakes, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:request_id, references(:decision_requests, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:requester_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:source_key, :text, null: false)
      add(:route, :text, null: false)
      add(:worker_event_id, references(:cooperation_events, type: :uuid, on_delete: :restrict))
      add(:worker_id, :text)
      add(:status, :text, null: false)
      add(:reservation_key, :text)
      add(:reserved_at, :timestamptz)
      add(:accepted_at, :timestamptz)
      add(:reason, :text)
      add(:answered_at, :timestamptz, null: false)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(unique_index(:decision_wakes, [:request_id]))
    create(unique_index(:decision_wakes, [:source_key]))
    create(index(:decision_wakes, [:requester_id, :status, :answered_at, :id]))

    create(
      constraint(:decision_wakes, :decision_wake_route,
        check:
          "(route='worker' AND worker_event_id IS NOT NULL AND worker_id=requester_id) OR (route='seat_watcher' AND worker_event_id IS NULL AND worker_id IS NULL)"
      )
    )

    create(
      constraint(:decision_wakes, :decision_wake_status,
        check: "status IN ('pending','reserved','accepted','uncertain','cancelled')"
      )
    )

    for table <- [:decision_requests, :decision_wakes] do
      version_table = :"#{table}_versions"

      create table(version_table, primary_key: false) do
        add(:id, :uuid, primary_key: true)
        add(:version_source_id, references(table, type: :uuid, on_delete: :restrict), null: false)
        add(:version_action_type, :text, null: false)
        add(:version_action_name, :text, null: false)
        add(:changes, :map)
        add(:provenance, :map, null: false)
        add(:version_inserted_at, :timestamptz, null: false)
        add(:version_updated_at, :timestamptz, null: false)
      end

      create(index(version_table, [:version_source_id, :version_inserted_at]))

      execute(
        "CREATE TRIGGER #{table}_versions_immutable BEFORE UPDATE OR DELETE ON #{version_table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_versions_no_truncate BEFORE TRUNCATE ON #{version_table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("""
    CREATE FUNCTION board_decision_hold(task text, owner_id text) RETURNS boolean
    LANGUAGE SQL VOLATILE AS $$
      SELECT EXISTS(SELECT 1 FROM decision_requests
        WHERE task_id=task AND requester_id=owner_id AND status IN ('open','answered'))
    $$
    """)

    execute("UPDATE board_schema SET version=GREATEST(version,20) WHERE id=1")
  end

  def down,
    do: raise("Preserve decisions, wake intents and audit history; use a compatible image")
end
