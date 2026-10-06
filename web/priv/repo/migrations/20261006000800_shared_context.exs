defmodule Agentboard.Repo.Migrations.SharedContext do
  use Ecto.Migration

  def up do
    # The CNPG operator installs the extension before application migrations.
    # Its superuser requirements must never be given to the API's database role.
    execute(
      "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_extension WHERE extname='pg_textsearch' AND extversion='1.5.1') THEN RAISE EXCEPTION 'Install pg_textsearch 1.5.1 before context migrations'; END IF; END $$"
    )

    create table(:context_entries) do
      add(:entry_key, :text, null: false)
      add(:repo, :text, null: false)
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict))
      add(:pr_url, :text)
      add(:source_revision, :text)
      add(:kind, :text, null: false)
      add(:summary, :text, null: false)
      add(:detail, :text, null: false, default: "")
      add(:evidence_urls, {:array, :text}, null: false, default: [])
      add(:source_agent_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:digest, :text, null: false)
      add(:created_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
    end

    execute(
      "ALTER TABLE context_entries ADD COLUMN search_text text GENERATED ALWAYS AS (summary || ' ' || detail) STORED"
    )

    create(
      unique_index(:context_entries, [:source_agent_id, :entry_key],
        name: :context_entries_author_key
      )
    )

    create(index(:context_entries, [:repo, :id]))
    create(index(:context_entries, [:task_id, :id]))

    create(
      constraint(:context_entries, :context_contract,
        check:
          "entry_key ~ '^[a-z0-9][a-z0-9_-]{0,127}$' AND repo ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' AND kind IN ('OBSERVED','FACT','FAIL','CLAIM','PATCH_SUMMARY') AND octet_length(summary) BETWEEN 1 AND 600 AND length(btrim(summary))>0 AND octet_length(detail)<=16384 AND cardinality(evidence_urls)<=20 AND digest ~ '^[a-f0-9]{64}$' AND length(btrim(model))>0 AND length(btrim(harness))>0"
      )
    )

    execute(
      "CREATE INDEX context_entries_bm25 ON context_entries USING bm25 (search_text) WITH (text_config='simple')"
    )

    create table(:context_links, primary_key: false) do
      add(:entry_id, references(:context_entries, on_delete: :restrict), primary_key: true)
      add(:target_id, references(:context_entries, on_delete: :restrict), primary_key: true)
      add(:relation, :text, primary_key: true)
    end

    create(index(:context_links, [:target_id]))

    create(
      constraint(:context_links, :context_relation,
        check:
          "entry_id<>target_id AND relation IN ('supports','contradicts','supersedes','depends_on')"
      )
    )

    execute(
      "CREATE FUNCTION context_link_repo_guard() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF (SELECT repo FROM context_entries WHERE id=NEW.entry_id) IS DISTINCT FROM (SELECT repo FROM context_entries WHERE id=NEW.target_id) THEN RAISE EXCEPTION 'Context links require the same repository'; END IF; RETURN NEW; END $$"
    )

    execute(
      "CREATE TRIGGER context_link_repo BEFORE INSERT ON context_links FOR EACH ROW EXECUTE FUNCTION context_link_repo_guard()"
    )

    create table(:context_receipts, primary_key: false) do
      add(:entry_id, references(:context_entries, on_delete: :restrict), primary_key: true)

      add(:source_agent_id, references(:agents, type: :text, on_delete: :restrict),
        primary_key: true
      )

      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:created_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
    end

    for table <- ~w(context_entries context_links context_receipts) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION board_reject_history_change()"
      )

      execute(
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION board_reject_history_change()"
      )
    end

    execute("UPDATE board_schema SET version=5 WHERE id=1")
  end

  def down, do: raise("Preserve context history; roll back a compatible application image")
end

