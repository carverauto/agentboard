defmodule Agentboard.SchemaVersion do
  @required 6
  def required, do: @required

  def current do
    case Agentboard.Repo.statement(
           "SELECT version FROM board_schema WHERE id = 1 AND to_regclass('archive_policy') IS NOT NULL AND to_regclass('task_archives') IS NOT NULL AND to_regclass('oban_jobs') IS NOT NULL AND to_regclass('context_entries') IS NOT NULL AND to_regclass('context_links') IS NOT NULL AND to_regclass('context_receipts') IS NOT NULL AND to_regclass('board_action_events') IS NOT NULL AND to_regclass('tasks_versions') IS NOT NULL",
           [],
           timeout: 2_000
         ) do
      {:ok, %{rows: [[version]]}} when version >= @required -> {:ok, version}
      _ -> {:error, :unavailable}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end
end

