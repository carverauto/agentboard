defmodule Agentboard.Repo.Migrations.AgentAvailability do
  use Ecto.Migration

  def up do
    create table(:availability_policies, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:agent_id, references(:agents, type: :text, on_delete: :restrict))
      add(:harness, :text)
      add(:model_pattern, :text)
      add(:state, :text, null: false)
      add(:reason, :text)
      add(:until, :timestamptz)
      add(:revision, :integer, null: false)
      add(:changed_by, :text, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:availability_policies, :availability_state,
        check:
          "state IN ('active','reserved','out_of_service') AND (\"until\" IS NULL OR state='out_of_service')"
      )
    )

    create(
      constraint(:availability_policies, :availability_selector,
        check:
          "(agent_id IS NOT NULL AND harness IS NULL AND model_pattern IS NULL) OR (agent_id IS NULL AND (harness IS NOT NULL OR model_pattern IS NOT NULL))"
      )
    )

    create(index(:availability_policies, [:until], where: "state='out_of_service'"))

    create table(:availability_policies_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:availability_policies, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:availability_policies_versions, [:version_source_id, :version_inserted_at]))

    execute(
      "CREATE TRIGGER availability_versions_immutable BEFORE UPDATE OR DELETE ON availability_policies_versions FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER availability_versions_no_truncate BEFORE TRUNCATE ON availability_policies_versions FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    alter(table(:tasks), do: add(:assignment_authorized, :boolean, null: false, default: false))
    alter(table(:messages), do: add(:kind, :text, null: false, default: "note"))

    create(
      constraint(:messages, :message_kind,
        check:
          "kind IN ('note','task_order') AND (kind <> 'task_order' OR recipient_id IS NOT NULL)"
      )
    )

    execute("""
    CREATE FUNCTION board_agent_availability(agent text, agent_harness text, agent_model text)
    RETURNS jsonb LANGUAGE SQL VOLATILE AS $$
      SELECT COALESCE((
        SELECT jsonb_build_object(
          'state', CASE WHEN state='out_of_service' AND "until" <= clock_timestamp() THEN 'active' ELSE state END,
          'source', id, 'agent_id', agent_id, 'harness', harness, 'model_pattern', model_pattern,
          'reason', reason, 'until', "until", 'revision', revision, 'changed_by', changed_by,
          'expired', coalesce(state='out_of_service' AND "until" <= clock_timestamp(),false))
        FROM availability_policies
        WHERE agent_id=agent OR (agent_id IS NULL
          AND (harness IS NULL OR harness=agent_harness)
          AND (model_pattern IS NULL OR model_pattern=agent_model OR
            (right(model_pattern,1)='*' AND left(agent_model,length(model_pattern)-1)=left(model_pattern,length(model_pattern)-1))))
        ORDER BY (agent_id IS NOT NULL) DESC,
          CASE WHEN harness IS NOT NULL AND model_pattern IS NOT NULL THEN 3 WHEN model_pattern IS NOT NULL THEN 2 ELSE 1 END DESC,
          (right(coalesce(model_pattern,''),1)<>'*') DESC, length(coalesce(model_pattern,'')) DESC, id ASC
        LIMIT 1
      ), '{"state":"active","source":"default","reason":null,"until":null,"expired":false}'::jsonb)
    $$
    """)

    execute("UPDATE board_schema SET version=15 WHERE id=1")
  end

  def down, do: raise("Preserve availability and audit history; use a compatible image")
end
