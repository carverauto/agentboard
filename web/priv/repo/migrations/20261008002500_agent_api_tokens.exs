defmodule Agentboard.Repo.Migrations.AgentApiTokens do
  use Ecto.Migration

  def up do
    create table(:agent_api_credentials, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:agent_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:token_hash, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:scope, :text, null: false)
      add(:issuer, :text, null: false)
      add(:created_at, :timestamptz, null: false)
      add(:last_used_at, :timestamptz)
      add(:revoked_at, :timestamptz)
    end

    create(unique_index(:agent_api_credentials, [:token_hash]))
    create(index(:agent_api_credentials, [:agent_id, :created_at]))

    create(
      constraint(:agent_api_credentials, :agent_credential_scope,
        check: "scope IN ('agent','coordinator','system','captain-admin')"
      )
    )

    create(
      constraint(:agent_api_credentials, :agent_credential_digest,
        check: "token_hash ~ '^[0-9a-f]{64}$' AND fingerprint=left(token_hash,12)"
      )
    )

    create table(:agent_auth_observations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:outcome, :text, null: false)
      add(:attributed_agent_id, references(:agents, type: :text, on_delete: :restrict))
      add(:verified_agent_id, references(:agents, type: :text, on_delete: :restrict))
      add(:method, :text, null: false)
      add(:route, :text, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(index(:agent_auth_observations, [:created_at, :id]))
    create(index(:agent_auth_observations, [:attributed_agent_id, :created_at]))

    create(
      constraint(:agent_auth_observations, :agent_auth_outcome,
        check: "outcome IN ('anonymous','invalid','actor_mismatch','matched')"
      )
    )

    execute("""
    CREATE FUNCTION agent_api_credential_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF (to_jsonb(NEW)-ARRAY['last_used_at','revoked_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['last_used_at','revoked_at']) OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
        RAISE EXCEPTION 'immutable credential';
      END IF;
      RETURN NEW;
    END; $$;
    """)

    execute(
      "CREATE TRIGGER agent_api_credential_immutable BEFORE UPDATE ON agent_api_credentials FOR EACH ROW EXECUTE FUNCTION agent_api_credential_guard();"
    )

    execute(
      "CREATE TRIGGER agent_auth_observation_append_only BEFORE UPDATE OR DELETE ON agent_auth_observations FOR EACH ROW EXECUTE FUNCTION board_reject_history_change();"
    )

    execute(
      "CREATE TRIGGER agent_auth_observation_no_truncate BEFORE TRUNCATE ON agent_auth_observations FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change();"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,25) WHERE id=1;")
  end

  def down do
    raise "Agent credential/audit rollback retains evidence; change mode to off"
  end
end
