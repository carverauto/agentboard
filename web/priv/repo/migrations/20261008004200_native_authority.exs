defmodule Agentboard.Repo.Migrations.NativeAuthority do
  use Ecto.Migration

  def up do
    create table(:cooperation_native_approvals, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:worker_id, references(:cooperation_subscriptions, type: :text, on_delete: :restrict),
        null: false
      )

      add(:expected_authority_revision, :bigint, null: false)
      add(:authority_revision, :bigint, null: false)
      add(:idempotency_key, :text, null: false)
      add(:manifest, :map, null: false)
      add(:manifest_sha256, :text, null: false)
      add(:approved_by, :text, null: false)
      add(:approved_at, :timestamptz, null: false)
    end

    create(unique_index(:cooperation_native_approvals, [:worker_id, :idempotency_key]))

    create(
      constraint(:cooperation_native_approvals, :native_approval_shape,
        check:
          "id ~ '^[A-Za-z0-9_.:-]{1,128}$' AND expected_authority_revision>=0 AND authority_revision=expected_authority_revision+1 AND authority_revision<=9007199254740991 AND octet_length(idempotency_key) BETWEEN 1 AND 128 AND manifest_sha256 ~ '^[a-f0-9]{64}$' AND approved_by='captain' AND octet_length(manifest::text)<=16384"
      )
    )

    execute(
      "CREATE TRIGGER cooperation_native_approvals_immutable BEFORE UPDATE OR DELETE ON cooperation_native_approvals FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER cooperation_native_approvals_no_truncate BEFORE TRUNCATE ON cooperation_native_approvals FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    alter table(:cooperation_bindings) do
      add(:native_authority_revision, :bigint, null: false, default: 0)

      add(
        :native_approval_id,
        references(:cooperation_native_approvals, type: :text, on_delete: :restrict)
      )

      add(:native_retire_key, :text)
      add(:native_retire_expected_revision, :bigint)
      add(:native_retire_revision, :bigint)
    end

    create(
      constraint(:cooperation_bindings, :native_authority_shape,
        check:
          "native_authority_revision BETWEEN 0 AND 9007199254740991 AND ((native_retire_key IS NULL AND native_retire_expected_revision IS NULL AND native_retire_revision IS NULL) OR (native_retire_key IS NOT NULL AND native_retire_expected_revision IS NOT NULL AND native_retire_revision IS NOT NULL AND octet_length(native_retire_key) BETWEEN 1 AND 128 AND native_retire_expected_revision BETWEEN 0 AND 9007199254740991 AND native_retire_revision BETWEEN native_retire_expected_revision AND native_retire_expected_revision+1 AND native_retire_revision<=native_authority_revision))"
      )
    )

    execute("UPDATE board_schema SET version=GREATEST(version,42) WHERE id=1")
  end

  # Existing code would ignore the fence and downgrade silently. Keep immutable
  # approvals and their audit history; deployment rollback needs compatible code.
  def down, do: raise("Retain native approval and authority fences; use compatible code")
end
