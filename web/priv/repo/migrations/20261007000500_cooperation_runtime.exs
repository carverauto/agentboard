defmodule Agentboard.Repo.Migrations.CooperationRuntime do
  use Ecto.Migration

  def up do
    drop(constraint(:delivery_ci_snapshots, :valid_observation))

    create(
      constraint(:delivery_ci_snapshots, :valid_observation,
        check:
          "generation>0 AND ci_state IN ('unknown','pending','failing','passing') AND lifecycle IN ('open','closed','merged') AND head_sha ~ '^[0-9a-f]{40}$' AND base_sha ~ '^[0-9a-f]{40}$' AND octet_length(payload::text)<=262144 AND (ci_state != 'passing' OR ((payload->>'policy'='verified' AND payload->>'coverage'='complete_head' AND payload->>'tested_ref'='head') IS TRUE))"
      )
    )

    execute(
      "INSERT INTO agents(id,name,model,harness,capabilities,metadata,created_at,updated_at) VALUES ('ci-accountability','CI accountability (server)','system','ash','{}','{}',transaction_timestamp(),transaction_timestamp()) ON CONFLICT DO NOTHING"
    )

    execute(
      "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM agents WHERE id='ci-accountability' AND model='system' AND harness='ash') THEN RAISE EXCEPTION 'Reserved ci-accountability system identity conflicts with an existing agent; preserve it and resolve explicitly before migrating'; END IF; END $$"
    )

    create table(:cooperation_subscriptions, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:host_id, :text, null: false)
      add(:repos, {:array, :text}, null: false)
      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:paused, :boolean, null: false)
      add(:revoked, :boolean, null: false)
      add(:enrolled_at, :timestamptz, null: false)
    end

    create table(:cooperation_bindings, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:epoch, :bigint, null: false)
      add(:generation, :bigint, null: false)
      add(:session_id, :text)
      add(:pane_id, :text)
      add(:adapter, :text)
      add(:adapter_version, :text)
      add(:capabilities, :map, null: false)
      add(:connector_state, :text, null: false)
      add(:adapter_state, :text, null: false)
      add(:reason, :text)
      add(:active_attempt_id, :uuid)
      add(:reported_at, :timestamptz)
      add(:updated_at, :timestamptz, null: false)
    end

    create table(:cooperation_credentials, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:worker_id, :text, null: false)
      add(:token_hash, :text, null: false)
      add(:scope, :text, null: false)
      add(:epoch, :bigint)
      add(:idempotency_key, :text, null: false)
      add(:revoked_at, :timestamptz)
      add(:created_at, :timestamptz, null: false)
    end

    create table(:cooperation_events, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:source_key, :text, null: false)
      add(:kind, :text, null: false)
      add(:repo, :text, null: false)
      add(:task_id, :text)
      add(:context_id, :bigint)
      add(:summary, :text, null: false)
      add(:source_url, :text, null: false)
      add(:priority, :bigint, null: false)
      add(:audience, {:array, :text}, null: false)
      add(:route_cursor, :bigint, null: false)
      add(:routed, :boolean, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create table(:cooperation_deliveries, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:event_id, :uuid, null: false)
      add(:worker_id, :text, null: false)
      add(:state, :text, null: false)
      add(:received_at, :timestamptz)
      add(:handled_at, :timestamptz)
      add(:created_at, :timestamptz, null: false)
    end

    create table(:cooperation_batches, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:worker_id, :text, null: false)
      add(:epoch, :bigint, null: false)
      add(:generation, :bigint, null: false)
      add(:delivery_ids, {:array, :text}, null: false)
      add(:payload, :text, null: false)
      add(:payload_hash, :text, null: false)
      add(:more, :boolean, null: false)
      add(:lease_expires_at, :timestamptz, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create table(:cooperation_attempts, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:batch_id, :uuid, null: false)
      add(:worker_id, :text, null: false)
      add(:epoch, :bigint, null: false)
      add(:generation, :bigint, null: false)
      add(:idempotency_key, :text, null: false)
      add(:status, :text, null: false)
      add(:reason, :text)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create table(:cooperation_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:worker_id, :text, null: false)
      add(:idempotency_key, :text, null: false)
      add(:digest, :text, null: false)
      add(:attempt_id, :uuid, null: false)
      add(:kind, :text, null: false)
      add(:delivery_ids, {:array, :text}, null: false)
      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create table(:delivery_obligations, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:pull_request_id, :text, null: false)
      add(:episode, :bigint, null: false)
      add(:repair_task_id, :text, null: false)
      add(:responsible_id, :text)
      add(:state, :text, null: false)
      add(:snapshot_id, references(:delivery_ci_snapshots, type: :uuid, on_delete: :restrict))
      add(:evidence_urls, {:array, :text}, null: false)
      add(:head_sha, :text, null: false)
      add(:last_progress_at, :timestamptz, null: false)
      add(:blocker, :text)
      add(:next_reminder_at, :timestamptz, null: false)
      add(:reminder_generation, :bigint, null: false)
      add(:window_at, :timestamptz, null: false)
      add(:reminders, :bigint, null: false)
      add(:escalated_at, :timestamptz)
      add(:resolved_at, :timestamptz)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:cooperation_credentials, [:token_hash]))
    create(unique_index(:cooperation_credentials, [:worker_id, :scope, :idempotency_key]))
    create(unique_index(:cooperation_events, [:source_key]))
    create(unique_index(:cooperation_deliveries, [:event_id, :worker_id]))
    create(unique_index(:cooperation_attempts, [:worker_id, :idempotency_key]))
    create(unique_index(:cooperation_receipts, [:worker_id, :idempotency_key]))
    create(unique_index(:delivery_obligations, [:pull_request_id, :episode]))

    create(
      unique_index(:delivery_obligations, [:pull_request_id],
        where: "resolved_at IS NULL",
        name: :delivery_one_active_obligation
      )
    )

    create(index(:cooperation_events, [:routed, :id]))
    create(index(:cooperation_deliveries, [:worker_id, :state, :id]))
    create(index(:delivery_obligations, [:responsible_id, :id]))
    create(index(:cooperation_batches, [:worker_id, :id]))

    execute(
      "CREATE TRIGGER cooperation_batches_immutable BEFORE UPDATE OR DELETE ON cooperation_batches FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER cooperation_receipts_immutable BEFORE UPDATE OR DELETE ON cooperation_receipts FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "ALTER TABLE cooperation_batches ADD CONSTRAINT bounded_frame CHECK (octet_length(payload) <= 16384 AND cardinality(delivery_ids) BETWEEN 1 AND 20)"
    )

    create table(:cooperation_bindings_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:cooperation_bindings, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    execute(
      "CREATE TRIGGER cooperation_bindings_versions_immutable BEFORE UPDATE OR DELETE ON cooperation_bindings_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    create table(:cooperation_subscriptions_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:cooperation_subscriptions, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    execute(
      "CREATE TRIGGER cooperation_subscriptions_versions_immutable BEFORE UPDATE OR DELETE ON cooperation_subscriptions_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "ALTER TABLE cooperation_deliveries ADD CONSTRAINT runtime_delivery_state CHECK (state IN ('pending','received','handled','suppressed'))"
    )

    execute(
      "ALTER TABLE cooperation_attempts ADD CONSTRAINT runtime_attempt_state CHECK (status IN ('reserved','submitted','not_submitted','uncertain','handled'))"
    )

    execute(
      "ALTER TABLE cooperation_subscriptions ADD CONSTRAINT runtime_worker FOREIGN KEY (id) REFERENCES agents(id)"
    )

    execute(
      "ALTER TABLE cooperation_bindings ADD CONSTRAINT runtime_binding_worker FOREIGN KEY (id) REFERENCES cooperation_subscriptions(id)"
    )

    execute(
      "ALTER TABLE cooperation_deliveries ADD CONSTRAINT runtime_delivery_event FOREIGN KEY (event_id) REFERENCES cooperation_events(id)"
    )

    execute(
      "ALTER TABLE cooperation_deliveries ADD CONSTRAINT runtime_delivery_worker FOREIGN KEY (worker_id) REFERENCES cooperation_subscriptions(id)"
    )

    execute(
      "ALTER TABLE cooperation_attempts ADD CONSTRAINT runtime_attempt_batch FOREIGN KEY (batch_id) REFERENCES cooperation_batches(id)"
    )

    execute(
      "ALTER TABLE cooperation_receipts ADD CONSTRAINT runtime_receipt_attempt FOREIGN KEY (attempt_id) REFERENCES cooperation_attempts(id)"
    )

    execute(
      "ALTER TABLE delivery_obligations ADD CONSTRAINT runtime_obligation_pr FOREIGN KEY (pull_request_id) REFERENCES delivery_pull_requests(id)"
    )

    execute(
      "ALTER TABLE delivery_obligations ADD CONSTRAINT runtime_obligation_task FOREIGN KEY (repair_task_id) REFERENCES tasks(id)"
    )

    execute(
      "ALTER TABLE delivery_obligations ADD CONSTRAINT runtime_obligation_owner FOREIGN KEY (responsible_id) REFERENCES agents(id)"
    )

    execute(
      "CREATE FUNCTION cooperation_guard_source() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF (to_jsonb(NEW) - ARRAY['routed','route_cursor']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['routed','route_cursor']) THEN RAISE EXCEPTION 'Cooperation source facts are immutable'; END IF; RETURN NEW; END $$"
    )

    execute(
      "CREATE TRIGGER cooperation_source_immutable BEFORE UPDATE ON cooperation_events FOR EACH ROW EXECUTE FUNCTION cooperation_guard_source()"
    )

    execute(
      "CREATE TRIGGER cooperation_source_no_delete BEFORE DELETE ON cooperation_events FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER cooperation_source_no_truncate BEFORE TRUNCATE ON cooperation_events FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER cooperation_batches_no_truncate BEFORE TRUNCATE ON cooperation_batches FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER cooperation_receipts_no_truncate BEFORE TRUNCATE ON cooperation_receipts FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute("UPDATE board_schema SET version=11 WHERE id=1")
  end

  def down,
    do: raise("Preserve pending delivery/accountability; use a schema-compatible rollback")
end
