defmodule Agentboard.Repo.Migrations.ChatSpoolPrivateRoutes do
  use Ecto.Migration

  # Additive only. Existing rows, outbox intents and coverage receipts are not
  # touched, and nothing is created for historical sends.
  def up do
    # Protected outbound spool for generic agent chat. A send is recorded here
    # before any network call; bodies are bounded, retained only while an
    # outcome is unresolved, purged at expiry and never indexed for search.
    execute("""
    CREATE TABLE conversation_spool (
      msg_id text PRIMARY KEY,
      agent_id text NOT NULL,
      channel_id text NOT NULL,
      root_id text,
      task_id text NOT NULL,
      kind text NOT NULL,
      retry_key text,
      recipient_id text,
      body text,
      body_sha256 text NOT NULL,
      state text NOT NULL,
      reason text,
      resolution text,
      post_id text,
      duplicate_post_ids text[] NOT NULL DEFAULT '{}',
      attempts integer NOT NULL DEFAULT 1,
      created_at timestamptz NOT NULL,
      submitted_at timestamptz,
      resolved_at timestamptz,
      expires_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT conversation_spool_shape CHECK (
        state IN ('submitting', 'sent', 'uncertain', 'failed', 'abandoned', 'expired')
        AND octet_length(msg_id) BETWEEN 1 AND 128
        AND octet_length(agent_id) BETWEEN 1 AND 128
        AND octet_length(channel_id) BETWEEN 1 AND 128
        AND (retry_key IS NULL OR octet_length(retry_key) BETWEEN 1 AND 128)
        AND (body IS NULL OR octet_length(body) <= 65536)
        AND body_sha256 ~ '^[a-f0-9]{64}$'
        AND (state <> 'sent' OR post_id IS NOT NULL)
        AND (state NOT IN ('sent', 'failed', 'abandoned', 'expired') OR body IS NULL)
        AND attempts >= 0
      )
    )
    """)

    execute(
      "CREATE UNIQUE INDEX conversation_spool_retry_key ON conversation_spool (agent_id, retry_key) WHERE retry_key IS NOT NULL"
    )

    execute("CREATE INDEX conversation_spool_expiry ON conversation_spool (expires_at)")
    execute("CREATE INDEX conversation_spool_agent_state ON conversation_spool (agent_id, state)")
    execute("REVOKE ALL ON TABLE conversation_spool FROM PUBLIC")

    # One server-owned private channel per recipient agent, created by the
    # shared bot in the configured team. Agents never hold its credentials.
    execute("""
    CREATE TABLE mattermost_agent_routes (
      agent_id text PRIMARY KEY,
      team_id text NOT NULL,
      channel_name text NOT NULL UNIQUE,
      channel_id text NOT NULL UNIQUE,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT mattermost_agent_routes_shape CHECK (
        octet_length(agent_id) BETWEEN 1 AND 128
        AND channel_name ~ '^[a-z0-9][a-z0-9-]{1,63}$'
        AND channel_id ~ '^[A-Za-z0-9_-]{1,128}$'
      )
    )
    """)

    execute("REVOKE ALL ON TABLE mattermost_agent_routes FROM PUBLIC")
    execute("UPDATE board_schema SET version=GREATEST(version,43) WHERE id=1")
  end

  # Older code ignores both tables, so rollback keeps them: uncertain sends and
  # route mappings remain evidence against a blind replay.
  def down, do: raise("Retain chat spool and private route evidence; use compatible code")
end
