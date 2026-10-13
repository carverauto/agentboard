defmodule Agentboard.Repo.Migrations.WorkIntake do
  use Ecto.Migration

  # Additive only. Intake requests and items are new evidence; existing tasks,
  # events and outbox rows are not touched and nothing is created for them.
  def up do
    # One row per accepted request. The normalized payload and its digest
    # decide replay (same digest) versus conflict (same key, other digest).
    execute("""
    CREATE TABLE intake_requests (
      id uuid PRIMARY KEY,
      filer_id text NOT NULL REFERENCES agents(id) ON DELETE RESTRICT,
      request_key text NOT NULL,
      payload_sha256 text NOT NULL,
      payload jsonb NOT NULL,
      created_at timestamptz NOT NULL,
      CONSTRAINT intake_requests_shape CHECK (
        octet_length(request_key) BETWEEN 1 AND 128
        AND payload_sha256 ~ '^[a-f0-9]{64}$'
        AND jsonb_typeof(payload) = 'object'
      )
    )
    """)

    execute(
      "CREATE UNIQUE INDEX intake_requests_filer_key ON intake_requests (filer_id, request_key)"
    )

    # One row per filed card. `issue_state` is the GitHub issue outbox state;
    # card-only items stay `none`. Bodies live on the card, not here.
    execute("""
    CREATE TABLE intake_items (
      id uuid PRIMARY KEY,
      request_id uuid NOT NULL REFERENCES intake_requests(id) ON DELETE RESTRICT,
      position integer NOT NULL,
      task_id text NOT NULL UNIQUE REFERENCES tasks(id) ON DELETE RESTRICT,
      repository text NOT NULL,
      issue boolean NOT NULL,
      issue_state text NOT NULL,
      issue_url text,
      issue_number bigint,
      duplicate_issue_urls text[] NOT NULL DEFAULT '{}',
      reason text,
      last_error text,
      attempts integer NOT NULL DEFAULT 0,
      generation bigint NOT NULL DEFAULT 0,
      claim_run_id uuid,
      claimed_at timestamptz,
      next_attempt_at timestamptz,
      cancelled_at timestamptz,
      cancelled_by text,
      resolved_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT intake_items_shape CHECK (
        position BETWEEN 0 AND 9
        AND repository ~ '^[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+$'
        AND issue_state IN ('none', 'pending', 'creating', 'created', 'uncertain', 'abandoned', 'cancelled')
        AND issue = (issue_state <> 'none')
        AND (issue_state <> 'created' OR (issue_url IS NOT NULL AND issue_number IS NOT NULL))
        AND (issue_state <> 'uncertain' OR reason IS NOT NULL)
        AND (issue_state <> 'creating' OR (claim_run_id IS NOT NULL AND claimed_at IS NOT NULL))
        AND (issue_state NOT IN ('pending', 'creating') OR next_attempt_at IS NOT NULL)
        AND (cancelled_at IS NULL) = (cancelled_by IS NULL)
        AND (reason IS NULL OR octet_length(reason) <= 512)
        AND (last_error IS NULL OR octet_length(last_error) <= 512)
        AND attempts >= 0 AND generation >= 0
      ),
      CONSTRAINT intake_items_position UNIQUE (request_id, position)
    )
    """)

    execute(
      "CREATE INDEX intake_items_due ON intake_items (next_attempt_at, id) WHERE issue_state IN ('pending', 'creating')"
    )

    execute("REVOKE ALL ON TABLE intake_requests FROM PUBLIC")
    execute("REVOKE ALL ON TABLE intake_items FROM PUBLIC")

    # Server identity attributed on card-to-issue links. This migration is
    # its first legitimate origin; `system-` IDs cannot be registered.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM agents WHERE id='system-intake') THEN
        RAISE EXCEPTION 'Reserved system-intake identity conflicts with an existing agent; preserve it and resolve explicitly before migrating';
      END IF;
    END $$
    """)

    execute(
      "INSERT INTO agents(id,name,model,harness,kind,capabilities,metadata,created_at,updated_at) VALUES ('system-intake','Work intake (server)','system','ash','system','{}','{}',transaction_timestamp(),transaction_timestamp())"
    )

    execute("UPDATE board_schema SET version=GREATEST(version,45) WHERE id=1")
  end

  # Older code ignores both tables. Keep them: pending or uncertain issue
  # intents are evidence against a blind replay that could duplicate issues.
  def down, do: raise("Retain intake requests and issue outbox evidence; use compatible code")
end
