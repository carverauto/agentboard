defmodule Agentboard.Repo.Migrations.DecisionPolicy do
  use Ecto.Migration

  def up do
    alter table(:decision_requests) do
      add(:requested_ci_runs, :integer)
    end

    create(
      constraint(:decision_requests, :decision_ci_intent,
        check: "requested_ci_runs IS NULL OR requested_ci_runs BETWEEN 0 AND 100"
      )
    )

    create table(:decision_policy_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text, null: false)
      add(:version, :integer, null: false)
      add(:document, :map, null: false)
      add(:sha256, :text, null: false)
      add(:created_by, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:decision_policy_versions, [:name, :version]))

    create(
      constraint(:decision_policy_versions, :decision_policy_version_shape,
        check:
          "version > 0 AND sha256 ~ '^[0-9a-f]{64}$' AND created_by='captain' AND octet_length(document::text)<=1048576"
      )
    )

    create table(:decision_policy_approvals, primary_key: false) do
      add(:id, references(:decision_policy_versions, type: :uuid, on_delete: :restrict),
        primary_key: true
      )

      add(:sha256, :text, null: false)
      add(:approved_by, :text, null: false)
      add(:approved_at, :timestamptz, null: false)
    end

    create(
      constraint(:decision_policy_approvals, :decision_policy_approval_shape,
        check: "sha256 ~ '^[0-9a-f]{64}$' AND approved_by='captain'"
      )
    )

    create table(:decision_policy_state, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:active_id, references(:decision_policy_versions, type: :uuid, on_delete: :restrict))
      add(:generation, :bigint, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:decision_policy_state, :decision_policy_state_shape,
        check: "id='board' AND generation>=0"
      )
    )

    execute(
      "INSERT INTO decision_policy_state(id,generation,updated_at) VALUES ('board',0,transaction_timestamp())"
    )

    create table(:decision_policy_ledger, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:decision_id, references(:decision_requests, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:policy_id, references(:decision_policy_versions, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:gate_ref, :text, null: false)
      add(:policy_version, :integer, null: false)
      add(:policy_sha256, :text, null: false)
      add(:source_version, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:rule_id, :text)
      add(:answer, :text)
      add(:answer_sha256, :text)
      add(:limit_key, :text, null: false)
      add(:day, :date, null: false)
      add(:ci_runs, :integer, null: false)
      add(:result, :text, null: false)
      add(:reason, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(
      unique_index(
        :decision_policy_ledger,
        [:decision_id, :policy_id, :source_version, :generation, :day],
        name: :decision_policy_evaluation_identity
      )
    )

    create(
      unique_index(:decision_policy_ledger, [:decision_id],
        where: "result='answered'",
        name: :decision_policy_answer_once
      )
    )

    create(index(:decision_policy_ledger, [:limit_key, :day], where: "result='answered'"))

    create(
      constraint(:decision_policy_ledger, :decision_policy_ledger_shape,
        check:
          "policy_version>0 AND generation>0 AND ci_runs BETWEEN 0 AND 100 AND result IN ('answered','escalated') AND policy_sha256 ~ '^[0-9a-f]{64}$' AND source_version ~ '^[0-9a-f]{64}$' AND ((result='answered' AND answer IS NOT NULL AND answer_sha256 ~ '^[0-9a-f]{64}$' AND rule_id IS NOT NULL) OR (result='escalated' AND answer IS NULL AND answer_sha256 IS NULL AND ci_runs=0))"
      )
    )

    for table <- ~w(decision_policy_versions decision_policy_approvals decision_policy_ledger) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("""
    CREATE FUNCTION board_require_policy_answer() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_TABLE_NAME='decision_policy_ledger' THEN
        IF NEW.result='answered' AND NOT EXISTS (
          SELECT 1 FROM decision_requests WHERE id=NEW.decision_id
          AND answer=NEW.answer AND answered_by='system-decision-policy' AND status IN ('answered','applied')
        ) THEN RAISE EXCEPTION 'conflict' USING DETAIL='Policy ledger requires the matching canonical answer'; END IF;
      ELSIF NEW.answered_by='system-decision-policy' AND NOT EXISTS (
        SELECT 1 FROM decision_policy_ledger WHERE decision_id=NEW.id AND result='answered' AND answer=NEW.answer
      ) THEN RAISE EXCEPTION 'conflict' USING DETAIL='Policy answer requires its immutable ledger';
      END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER decision_policy_answer_ledger AFTER INSERT OR UPDATE ON decision_requests DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION board_require_policy_answer()"
    )

    execute(
      "CREATE CONSTRAINT TRIGGER decision_policy_ledger_answer AFTER INSERT ON decision_policy_ledger DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION board_require_policy_answer()"
    )

    # This migration is the first legitimate origin of the reserved identity.
    # Matching client-writable metadata cannot prove a pre-existing row's origin.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM agents WHERE id='system-decision-policy') THEN
        RAISE EXCEPTION 'Reserved system-decision-policy identity conflicts with an existing agent; preserve it and resolve explicitly before migrating';
      END IF;
    END $$
    """)

    execute(
      "INSERT INTO agents(id,name,model,harness,kind,capabilities,metadata,created_at,updated_at) VALUES ('system-decision-policy','Decision policy (server)','system','ash','system','{}','{}',transaction_timestamp(),transaction_timestamp())"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,41) WHERE id=1")
  end

  def down,
    do: raise("Retain approved policies and immutable answer evidence; use compatible code")
end
