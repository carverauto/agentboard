defmodule Agentboard.Repo.Migrations.RepositoryMetadata do
  use Ecto.Migration

  def up do
    create table(:delivery_repository_metadata, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:generation, :bigint, null: false, default: 0)
      add(:source_generation, :bigint)
      add(:default_ref, :text)
      add(:observed_at, :timestamptz)
      add(:source_run_id, references(:delivery_workflow_runs, type: :text, on_delete: :restrict))
      add(:source_run_generation, :bigint)
      add(:last_error, :text)
    end

    create(
      constraint(:delivery_repository_metadata, :delivery_repository_metadata_identity,
        check:
          "octet_length(id)<=256 AND id ~ '^[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+$' AND split_part(id,'/',2) NOT IN ('.','..')"
      )
    )

    create(
      constraint(:delivery_repository_metadata, :delivery_repository_metadata_source,
        check: """
        generation>=0 AND (
          (source_generation IS NULL AND default_ref IS NULL AND observed_at IS NULL
            AND source_run_id IS NULL AND source_run_generation IS NULL)
          OR (source_generation IS NOT NULL AND source_generation>0 AND source_generation<=generation
            AND default_ref IS NOT NULL AND octet_length(default_ref) BETWEEN 1 AND 255
            AND default_ref !~ '[[:cntrl:]]' AND observed_at IS NOT NULL
            AND source_run_id IS NOT NULL AND starts_with(lower(source_run_id),id || '/')
            AND substring(source_run_id FROM char_length(id)+2) ~ '^[1-9][0-9]*$'
            AND source_run_generation IS NOT NULL AND source_run_generation>0)
        )
        """
      )
    )

    # Do not infer a default from historical run branches, enroll repositories,
    # enqueue work, or downgrade a concurrently applied higher schema marker.
    execute("UPDATE board_schema SET version=GREATEST(version,38) WHERE id=1")
  end

  def down,
    do: raise("Retain provider metadata and its audit history; use a compatible image")
end
