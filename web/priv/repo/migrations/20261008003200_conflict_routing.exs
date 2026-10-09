defmodule Agentboard.Repo.Migrations.ConflictRouting do
  @moduledoc "Schema32 reserved for retained publication/conflict evidence; no invented grants or deadlines."
  use Ecto.Migration

  def up do
    alter table(:delivery_poll_states) do
      add(:default_ref, :text)
      add(:expected_default_sha, :text)
    end

    create(
      constraint(:delivery_poll_states, :poll_default_identity,
        check:
          "(default_ref IS NULL)=(expected_default_sha IS NULL) AND (default_ref IS NULL OR (length(default_ref) BETWEEN 1 AND 255 AND expected_default_sha ~ '^[0-9a-f]{40}$'))"
      )
    )

    create table(:delivery_publication_bindings, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:repo, :text, null: false)
      add(:head_repo, :text, null: false)
      add(:branch, :text, null: false)
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:bound_by_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:generation, :bigint, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:delivery_publication_bindings, [:head_repo, :branch]))
    create(index(:delivery_publication_bindings, [:task_id, :id]))

    create(
      constraint(:delivery_publication_bindings, :binding_identity,
        check:
          "generation>0 AND length(branch) BETWEEN 1 AND 255 AND repo=lower(repo) AND head_repo=lower(head_repo)"
      )
    )

    create table(:delivery_conflict_orders, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)

      add(
        :pull_request_id,
        references(:delivery_pull_requests, type: :text, on_delete: :restrict),
        null: false
      )

      add(:episode_id, :uuid, null: false)
      add(:default_ref, :text, null: false)
      add(:default_tip_sha, :text, null: false)
      add(:evaluation_base_ref, :text, null: false)
      add(:evaluation_base_sha, :text, null: false)
      add(:trigger_head_sha, :text, null: false)
      add(:observed_head_sha, :text, null: false)

      add(:snapshot_id, references(:delivery_ci_snapshots, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:repair_task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:author_id, references(:agents, type: :text, on_delete: :restrict))
      add(:recipient_id, references(:agents, type: :text, on_delete: :restrict))
      add(:revision, :bigint, null: false)
      add(:state, :text, null: false)
      add(:episode_started_at, :timestamptz, null: false)
      add(:deadline_at, :timestamptz, null: false)
      add(:selection_reason, :text)
      add(:rebaser_id, references(:agents, type: :text, on_delete: :restrict))

      add(
        :escalation_decision_id,
        references(:decision_requests, type: :uuid, on_delete: :restrict)
      )

      add(:resolved_at, :timestamptz)

      add(
        :resolution_snapshot_id,
        references(:delivery_ci_snapshots, type: :uuid, on_delete: :restrict)
      )

      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      unique_index(:delivery_conflict_orders, [:pull_request_id, :default_ref],
        where: "state='open'",
        name: :conflict_order_one_current
      )
    )

    create(
      unique_index(
        :delivery_conflict_orders,
        [:pull_request_id, :default_ref, :default_tip_sha, :episode_id, :revision],
        name: :conflict_order_episode_tip
      )
    )

    create(index(:delivery_conflict_orders, [:deadline_at, :id], where: "state='open'"))
    create(index(:delivery_conflict_orders, [:repair_task_id, :id]))

    create(
      constraint(:delivery_conflict_orders, :conflict_order_evidence,
        check:
          "revision>0 AND default_tip_sha ~ '^[0-9a-f]{40}$' AND evaluation_base_sha ~ '^[0-9a-f]{40}$' AND trigger_head_sha ~ '^[0-9a-f]{40}$' AND observed_head_sha ~ '^[0-9a-f]{40}$' AND length(default_ref) BETWEEN 1 AND 255 AND length(evaluation_base_ref) BETWEEN 1 AND 255 AND episode_started_at<=created_at AND deadline_at>episode_started_at"
      )
    )

    create(
      constraint(:delivery_conflict_orders, :conflict_order_disposition,
        check:
          "state IN ('open','superseded','satisfied','cleared_without_repair','cancelled') AND ((state='open')=(resolved_at IS NULL)) AND ((state='satisfied')=(rebaser_id IS NOT NULL))"
      )
    )

    alter table(:delivery_rebase_follow_ups) do
      add(
        :current_order_id,
        references(:delivery_conflict_orders, type: :uuid, on_delete: :restrict)
      )
    end

    # Exact source identity, never a reference inferred from an inbox body.
    create table(:delivery_conflict_sources, primary_key: false) do
      add(:id, references(:cooperation_events, type: :uuid, on_delete: :restrict),
        primary_key: true
      )

      add(:order_id, references(:delivery_conflict_orders, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:order_revision, :bigint, null: false)
      add(:source_key, :text, null: false)
      add(:message_id, references(:messages, type: :bigint, on_delete: :restrict))
      add(:message_version, :text)
      add(:disposition, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:delivery_conflict_sources, [:order_id, :order_revision]))

    create(
      unique_index(:delivery_conflict_sources, [:message_id], where: "message_id IS NOT NULL")
    )

    create(
      constraint(:delivery_conflict_sources, :conflict_source_identity,
        check:
          "order_revision>0 AND source_key='conflict-order:'||order_id::text||':'||order_revision::text AND ((message_id IS NULL)=(message_version IS NULL)) AND disposition IN ('worker','sent','adopted','disabled','undeliverable')"
      )
    )

    execute(
      "CREATE TRIGGER conflict_source_immutable BEFORE UPDATE OR DELETE ON delivery_conflict_sources FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER conflict_source_no_truncate BEFORE TRUNCATE ON delivery_conflict_sources FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    create table(:delivery_publication_grants, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)

      add(
        :binding_id,
        references(:delivery_publication_bindings, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:binding_generation, :bigint, null: false)
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:holder_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:action, :text, null: false)
      add(:head_sha, :text, null: false)
      add(:default_ref, :text)
      add(:default_tip_sha, :text)
      add(:expected_remote_head, :text)
      add(:order_id, references(:delivery_conflict_orders, type: :uuid, on_delete: :restrict))
      add(:order_revision, :bigint)
      add(:repair_task_id, references(:tasks, type: :text, on_delete: :restrict))
      add(:custody_receipt_sha256, :text)
      add(:publication_nonce, :uuid, null: false)
      add(:state, :text, null: false)
      add(:expires_at, :timestamptz, null: false)
      add(:completed_pr_url, :text)
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(unique_index(:delivery_publication_grants, [:publication_nonce]))
    create(index(:delivery_publication_grants, [:binding_id, :id]))
    create(index(:delivery_publication_grants, [:expires_at, :id], where: "state='admitted'"))

    create(
      constraint(:delivery_publication_grants, :publication_grant_identity,
        check:
          "binding_generation>0 AND head_sha ~ '^[0-9a-f]{40}$' AND (default_tip_sha IS NULL OR default_tip_sha ~ '^[0-9a-f]{40}$') AND (expected_remote_head IS NULL OR expected_remote_head ~ '^[0-9a-f]{40}$') AND (custody_receipt_sha256 IS NULL OR custody_receipt_sha256 ~ '^[0-9a-f]{64}$') AND expires_at>created_at AND action IN ('push','pr_open','pr_update','repair_push') AND state IN ('pending','admitted','refused','revoked','completed')"
      )
    )

    create(
      constraint(:delivery_publication_grants, :publication_grant_proof,
        check:
          "state NOT IN ('admitted','completed') OR (default_ref IS NOT NULL AND default_tip_sha IS NOT NULL AND (action<>'repair_push' OR (order_id IS NOT NULL AND order_revision IS NOT NULL AND order_revision>0 AND repair_task_id IS NOT NULL AND custody_receipt_sha256 IS NOT NULL AND expected_remote_head IS NOT NULL)))"
      )
    )

    for source <- [
          :delivery_publication_bindings,
          :delivery_conflict_orders,
          :delivery_publication_grants
        ] do
      history = :"#{source}_versions"

      create table(history, primary_key: false) do
        add(:id, :uuid, primary_key: true, null: false)
        add(:version_action_type, :text, null: false)
        add(:version_action_name, :text, null: false)

        add(:version_source_id, references(source, type: :uuid, on_delete: :restrict),
          null: false
        )

        add(:changes, :map)
        add(:provenance, :map, null: false)
        add(:version_inserted_at, :timestamptz, null: false)
        add(:version_updated_at, :timestamptz, null: false)
      end

      create(index(history, [:version_source_id, :version_inserted_at]))

      execute(
        "CREATE TRIGGER #{history}_immutable BEFORE UPDATE OR DELETE ON #{history} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{history}_no_truncate BEFORE TRUNCATE ON #{history} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("UPDATE board_schema SET version=GREATEST(version,32) WHERE id=1")
  end

  def down, do: raise("Retain publication and conflict history; disable policy instead")
end
