defmodule Agentboard.Repo.Migrations.CreateBoard do
  use Ecto.Migration

  def up do
    create table(:board_schema, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:version, :integer, null: false)
    end

    create(constraint(:board_schema, :single_schema_marker, check: "id = 1 AND version > 0"))
    execute("INSERT INTO board_schema (id, version) VALUES (1, 1)")

    create table(:agents, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:name, :text, null: false)
      add(:harness, :text, null: false)
      add(:model, :text, null: false)
      add(:host, :text)
      add(:capabilities, {:array, :text}, null: false, default: [])
      add(:metadata, :map, null: false, default: %{})
      add(:reported_status, :text)
      add(:last_heartbeat, :timestamptz)
      add(:created_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
      add(:updated_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
    end

    create(constraint(:agents, :agent_slug, check: "id ~ '^[a-z0-9][a-z0-9_-]{0,127}$'"))

    create(
      constraint(:agents, :agent_context,
        check:
          "length(btrim(name)) > 0 AND length(btrim(model)) > 0 AND length(btrim(harness)) > 0"
      )
    )

    create(
      constraint(:agents, :agent_reported_status,
        check: "reported_status IS NULL OR reported_status IN ('busy','idle')"
      )
    )

    create(
      constraint(:agents, :agent_metadata_object, check: "jsonb_typeof(metadata) = 'object'")
    )

    create table(:tasks, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:title, :text, null: false)
      add(:description, :text, null: false, default: "")
      add(:priority, :integer, null: false, default: 3)
      add(:repo, :text)
      add(:labels, {:array, :text}, null: false, default: [])
      add(:issue_url, :text)
      add(:pr_url, :text)
      add(:status, :text, null: false, default: "open")
      add(:assignee_id, references(:agents, type: :text, on_delete: :restrict))
      add(:assigner_id, references(:agents, type: :text, on_delete: :restrict))
      add(:claimed_at, :timestamptz)
      add(:claim_expires_at, :timestamptz)
      add(:revision, :bigint, null: false, default: 1)
      add(:created_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
      add(:updated_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
    end

    create(constraint(:tasks, :task_slug, check: "id ~ '^[a-z0-9][a-z0-9_-]{0,127}$'"))

    create(
      constraint(:tasks, :task_metadata,
        check: "length(btrim(title)) > 0 AND priority >= 0 AND revision > 0"
      )
    )

    create(
      constraint(:tasks, :task_status,
        check: "status IN ('open','assigned','in_progress','blocked','review','done','cancelled')"
      )
    )

    create(
      constraint(:tasks, :task_ownership,
        check: """
          (status = 'open' AND assignee_id IS NULL AND assigner_id IS NULL AND claimed_at IS NULL AND claim_expires_at IS NULL)
          OR (status = 'assigned' AND assignee_id IS NOT NULL AND assigner_id IS NOT NULL AND claimed_at IS NULL AND claim_expires_at IS NULL)
          OR (status IN ('in_progress','blocked','review') AND assignee_id IS NOT NULL AND claimed_at IS NOT NULL AND claim_expires_at IS NOT NULL AND claim_expires_at > claimed_at)
          OR (status IN ('done','cancelled') AND claimed_at IS NULL AND claim_expires_at IS NULL)
        """
      )
    )

    create(
      constraint(:tasks, :task_issue_url,
        check:
          "issue_url IS NULL OR issue_url ~ '^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$'"
      )
    )

    create(
      constraint(:tasks, :task_pr_url,
        check:
          "pr_url IS NULL OR pr_url ~ '^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$'"
      )
    )

    create(index(:tasks, [:status, :priority, :updated_at, :id]))
    create(index(:tasks, [:assignee_id, :status]))
    create(index(:tasks, [:repo, :status]))

    alter table(:agents) do
      add(:current_task_id, references(:tasks, type: :text, on_delete: :restrict))
    end

    create table(:task_events) do
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:actor_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:kind, :text, null: false)
      add(:body, :text)
      add(:old_revision, :bigint)
      add(:new_revision, :bigint, null: false)
      add(:data, :map, null: false, default: %{})
      add(:created_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
    end

    create(
      constraint(:task_events, :event_provenance,
        check:
          "length(btrim(model)) > 0 AND length(btrim(harness)) > 0 AND length(btrim(kind)) > 0 AND new_revision > 0"
      )
    )

    create(index(:task_events, [:task_id, :created_at, :id]))

    execute("""
    CREATE FUNCTION board_reject_history_change() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Task history is append-only';
    END
    $$
    """)

    execute(
      "CREATE TRIGGER task_events_immutable BEFORE UPDATE OR DELETE ON task_events FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER task_events_no_truncate BEFORE TRUNCATE ON task_events FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute("""
    CREATE FUNCTION board_actor(p_actor text, p_model text, p_harness text) RETURNS void LANGUAGE plpgsql AS $$
    BEGIN
      IF p_actor IS NULL OR p_model IS NULL OR p_harness IS NULL OR length(btrim(p_model)) = 0 OR length(btrim(p_harness)) = 0 THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid_context', DETAIL = 'Agent, model, and harness are required';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM agents WHERE id = p_actor AND harness = p_harness) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid_context', DETAIL = 'Register a matching agent identity first';
      END IF;
    END
    $$
    """)
  end

  def down do
    raise "Board migrations are additive; preserve data and roll back the compatible application image"
  end
end

