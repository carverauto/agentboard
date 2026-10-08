defmodule Agentboard.SchemaVersion do
  @required 22
  def required, do: @required

  def current do
    case Agentboard.Repo.statement(
           "SELECT version FROM board_schema WHERE id = 1 AND to_regclass('archive_policy') IS NOT NULL AND to_regclass('task_archives') IS NOT NULL AND to_regclass('oban_jobs') IS NOT NULL AND to_regclass('context_entries') IS NOT NULL AND to_regclass('context_links') IS NOT NULL AND to_regclass('context_receipts') IS NOT NULL AND to_regclass('board_action_events') IS NOT NULL AND to_regclass('tasks_versions') IS NOT NULL AND to_regclass('delivery_pull_requests') IS NOT NULL AND to_regclass('delivery_task_links') IS NOT NULL AND to_regclass('delivery_poll_states') IS NOT NULL AND to_regclass('delivery_poll_states_versions') IS NOT NULL AND to_regclass('delivery_provider_budgets') IS NOT NULL AND to_regclass('delivery_ci_snapshots') IS NOT NULL AND to_regclass('cooperation_receipts') IS NOT NULL AND to_regclass('delivery_obligations') IS NOT NULL AND to_regclass('conversation_coverage') IS NOT NULL AND to_regclass('availability_policies') IS NOT NULL AND to_regclass('decision_requests') IS NOT NULL AND to_regclass('decision_wakes') IS NOT NULL AND to_regclass('delivery_base_watches') IS NOT NULL AND to_regclass('delivery_rebase_follow_ups') IS NOT NULL AND to_regclass('mattermost_agent_bots') IS NOT NULL AND to_regclass('mattermost_inbox') IS NOT NULL AND to_regclass('mattermost_post_versions') IS NOT NULL AND to_regclass('mattermost_channel_recovery') IS NOT NULL AND to_regclass('mattermost_inbound_runs') IS NOT NULL",
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
