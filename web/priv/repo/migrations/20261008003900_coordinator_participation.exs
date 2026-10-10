defmodule Agentboard.Repo.Migrations.CoordinatorParticipation do
  use Ecto.Migration

  def up do
    alter table(:agent_api_credentials) do
      add(:channel_ids, {:array, :text}, null: false, default: [])
    end

    drop(constraint(:agent_api_credentials, :agent_credential_scope))

    create(
      constraint(:agent_api_credentials, :agent_credential_scope,
        check:
          "scope IN ('agent','coordinator','coordinator_participant','system','captain-admin')"
      )
    )

    execute("""
    CREATE FUNCTION board_valid_participant_channels(channels text[]) RETURNS boolean
    LANGUAGE SQL IMMUTABLE STRICT AS $$
      SELECT cardinality(channels) BETWEEN 1 AND 20
        AND (SELECT count(DISTINCT value) FROM unnest(channels) AS value)=cardinality(channels)
        AND NOT EXISTS (SELECT 1 FROM unnest(channels) AS value
          WHERE value IS NULL OR octet_length(value) NOT BETWEEN 1 AND 128
            OR value !~ '^[A-Za-z0-9_-]+$')
    $$
    """)

    create(
      constraint(:agent_api_credentials, :agent_credential_channels,
        check:
          "(scope='coordinator_participant' AND board_valid_participant_channels(channel_ids)) OR (scope<>'coordinator_participant' AND cardinality(channel_ids)=0)"
      )
    )

    create table(:decision_conversation_intents, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:decision_id, references(:decision_requests, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:operation, :text, null: false)
      add(:actor_id, references(:agents, type: :text, on_delete: :restrict), null: false)

      add(:credential_id, references(:agent_api_credentials, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:channel_ids, {:array, :text}, null: false, default: [])
      add(:request_key, :text, null: false)
      add(:request_hash, :text, null: false)
      add(:source, :text, null: false)
      add(:repo, :text, null: false)
      add(:channel_id, :text, null: false)
      add(:root_id, :text, null: false, default: "")
      add(:recipient_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)

      add(:board_message_id, references(:messages, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(
        :parent_id,
        references(:decision_conversation_intents, type: :uuid, on_delete: :restrict)
      )

      add(:inbox_id, references(:mattermost_inbox, type: :uuid, on_delete: :restrict))
      add(:inbox_version, :text)
      add(:bot_user_id, :text)
      add(:msg_id, :text, null: false)
      add(:payload_hash, :text, null: false)
      add(:state, :text, null: false)
      add(:reason, :text)
      add(:post_id, :text)
      add(:post_version, :text)
      add(:post_metadata, :map)
      add(:duplicate_observed_at, :timestamptz)
      add(:duplicate_post_ids, {:array, :text}, null: false, default: [])
      add(:created_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
      add(:submitted_at, :timestamptz)
      add(:verified_at, :timestamptz)
    end

    create(
      unique_index(:decision_conversation_intents, [:decision_id],
        where: "operation='notify'",
        name: :decision_conversation_notice
      )
    )

    create(
      unique_index(:decision_conversation_intents, [:actor_id, :request_key],
        where: "operation='reply'",
        name: :decision_conversation_reply_key
      )
    )

    create(index(:decision_conversation_intents, [:source, :channel_id, :post_id, :post_version]))
    create(index(:decision_conversation_intents, [:recipient_id, :created_at]))

    create(
      constraint(:decision_conversation_intents, :decision_conversation_shape,
        check:
          "operation IN ('notify','reply') AND state IN ('prepared','submitting','sent','uncertain','blocked') AND request_hash ~ '^[0-9a-f]{64}$' AND payload_hash ~ '^[0-9a-f]{64}$' AND source ~ '^[0-9a-f]{64}$' AND (operation='notify' AND parent_id IS NULL AND inbox_id IS NULL AND inbox_version IS NULL OR operation='reply' AND parent_id IS NOT NULL AND inbox_id IS NOT NULL AND inbox_version ~ '^[0-9a-f]{64}$') AND (state<>'sent' OR (bot_user_id IS NOT NULL AND post_id IS NOT NULL AND post_version ~ '^[0-9a-f]{64}$' AND verified_at IS NOT NULL))"
      )
    )

    execute("""
    CREATE FUNCTION decision_conversation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF (to_jsonb(NEW)-ARRAY['state','reason','duplicate_observed_at','duplicate_post_ids','bot_user_id','post_id','post_version','post_metadata','submitted_at','verified_at','updated_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['state','reason','duplicate_observed_at','duplicate_post_ids','bot_user_id','post_id','post_version','post_metadata','submitted_at','verified_at','updated_at'])
         OR (OLD.bot_user_id IS NOT NULL AND NEW.bot_user_id IS DISTINCT FROM OLD.bot_user_id)
         OR (OLD.submitted_at IS NOT NULL AND NEW.submitted_at IS DISTINCT FROM OLD.submitted_at)
         OR (OLD.submitted_at IS NOT NULL AND NEW.state='prepared')
         OR (OLD.state='sent' AND (to_jsonb(NEW)-ARRAY['duplicate_observed_at','duplicate_post_ids','updated_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['duplicate_observed_at','duplicate_post_ids','updated_at']))
         OR (OLD.duplicate_observed_at IS NOT NULL AND (NEW.duplicate_observed_at IS DISTINCT FROM OLD.duplicate_observed_at OR NEW.duplicate_post_ids IS DISTINCT FROM OLD.duplicate_post_ids))
         OR (OLD.state='blocked' AND NEW.state IS DISTINCT FROM OLD.state)
         OR (OLD.reason='duplicate_posts_observed' AND (NEW.reason IS DISTINCT FROM OLD.reason OR NEW.state<>'uncertain'))
      THEN RAISE EXCEPTION 'immutable conversation intent or receipt'; END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE TRIGGER decision_conversation_immutable BEFORE UPDATE ON decision_conversation_intents FOR EACH ROW EXECUTE FUNCTION decision_conversation_guard()"
    )

    execute(
      "CREATE TRIGGER decision_conversation_no_delete BEFORE DELETE ON decision_conversation_intents FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER decision_conversation_no_truncate BEFORE TRUNCATE ON decision_conversation_intents FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,39) WHERE id=1")
  end

  def down,
    do:
      raise(
        "Retain participant grants and conversation evidence; revoke or disable routing with compatible code"
      )
end
