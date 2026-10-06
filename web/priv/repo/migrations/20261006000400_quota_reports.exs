defmodule Agentboard.Repo.Migrations.QuotaReports do
  use Ecto.Migration

  def up do
    create table(:quota_reports) do
      add(:source_agent_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:schema_version, :integer, null: false)
      add(:digest, :text, null: false)
      add(:generated_at, :timestamptz, null: false)
      add(:ingested_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
      add(:raw, :map, null: false)
    end

    create(
      constraint(:quota_reports, :quota_report_contract,
        check:
          "schema_version IN (5,6) AND length(btrim(model))>0 AND length(btrim(harness))>0 AND digest ~ '^[0-9a-f]{64}$' AND jsonb_typeof(raw)='object'"
      )
    )

    create(unique_index(:quota_reports, [:source_agent_id, :digest]))

    create table(:quota_observations) do
      add(:report_id, references(:quota_reports, on_delete: :restrict), null: false)
      add(:provider, :text, null: false)
      add(:account_key, :text, null: false)
      add(:provider_data, :map, null: false)
    end

    create(
      constraint(:quota_observations, :quota_identity,
        check:
          "length(btrim(provider))>0 AND length(btrim(account_key))>0 AND jsonb_typeof(provider_data)='object'"
      )
    )

    create(unique_index(:quota_observations, [:report_id, :provider, :account_key]))
    create(index(:quota_observations, [:provider, :account_key, :report_id]))

    create table(:quota_windows) do
      add(:observation_id, references(:quota_observations, on_delete: :restrict), null: false)
      add(:window_id, :text, null: false)
      add(:data, :map, null: false)
    end

    create(unique_index(:quota_windows, [:observation_id, :window_id]))

    create table(:quota_scopes) do
      add(:observation_id, references(:quota_observations, on_delete: :restrict), null: false)
      add(:scope, :text, null: false)
      add(:data, :map, null: false)
    end

    create(unique_index(:quota_scopes, [:observation_id, :scope]))

    Application.app_dir(:agentboard, "priv/sql/quota.sql")
    |> File.read!()
    |> String.split("\n-- statement-break\n")
    |> Enum.each(&execute/1)

    for table <- ~w(quota_reports quota_observations quota_windows quota_scopes) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("UPDATE board_schema SET version=3 WHERE id=1")
  end

  def down, do: raise("Preserve quota history; roll back a compatible application image")
end

