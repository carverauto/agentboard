defmodule Agentboard.Repo.Migrations.BranchFlowSettings do
  use Ecto.Migration

  def up do
    # The function keeps the database guard aligned with SeatScope.canonical_repo:
    # exact lowercase owner/repo, bounded bytes, no nulls or duplicate identities.
    execute("""
    CREATE FUNCTION branch_flow_valid_pins(pins text[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE STRICT AS $$
      SELECT coalesce(array_ndims(pins),1)=1 AND cardinality(pins)<=5
        AND cardinality(pins)=(SELECT count(DISTINCT repo) FROM unnest(pins) AS repo)
        AND NOT EXISTS (
          SELECT 1 FROM unnest(pins) AS repo
          WHERE repo IS NULL OR octet_length(repo)>256
            OR repo !~ '^[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+$'
            OR split_part(repo,'/',2) IN ('.','..')
        )
    $$
    """)

    create table(:branch_flow_configuration, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:pinned_repositories, {:array, :text}, null: false)
      add(:revision, :integer, null: false)
      add(:changed_by, :text, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:branch_flow_configuration, :branch_flow_configuration_shape,
        check:
          "id='branch-flow' AND revision>0 AND changed_by='captain' AND branch_flow_valid_pins(pinned_repositories)"
      )
    )

    create table(:branch_flow_configuration_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :version_source_id,
        references(:branch_flow_configuration, type: :text, on_delete: :restrict),
        null: false
      )

      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:changes, :map)
      add(:provenance, :map, null: false)
      add(:version_inserted_at, :timestamptz, null: false)
      add(:version_updated_at, :timestamptz, null: false)
    end

    create(index(:branch_flow_configuration_versions, [:version_source_id, :version_inserted_at]))

    create table(:branch_flow_receipts, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(
        :configuration_id,
        references(:branch_flow_configuration, type: :text, on_delete: :restrict),
        null: false
      )

      add(:idempotency_key, :text, null: false)
      add(:request, :map, null: false)
      add(:response, :map, null: false)
      add(:created_at, :timestamptz, null: false)
    end

    create(unique_index(:branch_flow_receipts, [:configuration_id, :idempotency_key]))

    create(
      constraint(:branch_flow_receipts, :branch_flow_receipt_shape,
        check:
          "configuration_id='branch-flow' AND octet_length(idempotency_key) BETWEEN 1 AND 128 AND jsonb_typeof(request)='object' AND jsonb_typeof(response)='object' AND request->>'idempotency_key'=idempotency_key"
      )
    )

    for table <- ~w(branch_flow_configuration_versions branch_flow_receipts) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    # No default row, inventory enrollment, evidence rewrite or configuration
    # backfill. Future schema markers must never be reduced by this migration.
    execute("UPDATE board_schema SET version=GREATEST(version,37) WHERE id=1")
  end

  def down,
    do: raise("Retain branch-flow configuration and immutable receipts; use a compatible image")
end
