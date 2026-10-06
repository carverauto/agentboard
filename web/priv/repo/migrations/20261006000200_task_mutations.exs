defmodule Agentboard.Repo.Migrations.TaskMutations do
  use Ecto.Migration

  def up do
    execute(File.read!(Application.app_dir(:agentboard, "priv/sql/task_mutations.sql")))
  end

  def down do
    raise "Preserve board history; roll back a compatible application image"
  end
end

