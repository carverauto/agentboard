defmodule Agentboard.Repo.Migrations.TaskDocuments do
  use Ecto.Migration

  def up do
    create table(:task_documents) do
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict), null: false)
      add(:source_agent_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:kind, :text, null: false)
      add(:title, :text, null: false)
      add(:html, :text, null: false)
      add(:digest, :text, null: false)
      add(:pr_url, :text)
      add(:source_revision, :text)
      add(:proposal_name, :text)
      add(:created_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
    end

    create(unique_index(:task_documents, [:task_id, :source_agent_id, :digest]))
    create(index(:task_documents, [:task_id, :id]))

    create(
      constraint(:task_documents, :document_contract,
        check:
          "kind IN ('archify','openspec') AND length(btrim(title)) BETWEEN 1 AND 256 AND octet_length(html) BETWEEN 1 AND 2097152 AND digest ~ '^[0-9a-f]{64}$'"
      )
    )

    Application.app_dir(:agentboard, "priv/sql/documents.sql")
    |> File.read!()
    |> String.split("\n-- statement-break\n")
    |> Enum.each(&execute/1)

    execute(
      "CREATE TRIGGER documents_immutable BEFORE UPDATE OR DELETE ON task_documents FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
    )

    execute(
      "CREATE TRIGGER documents_no_truncate BEFORE TRUNCATE ON task_documents FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
    )

    execute("UPDATE board_schema SET version=4 WHERE id=1")
  end

  def down, do: raise("Preserve documentation; roll back a compatible application image")
end

