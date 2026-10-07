defmodule Agentboard.Mattermost.ConversationCoverage do
  @moduledoc "Per-worker per-channel exact post/version coverage. Incomplete catch-up stays explicit; bodies live in Mattermost, never here."
  use Ash.Resource,
    domain: Agentboard.Mattermost,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("conversation_coverage")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_actions([:report])
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    ignore_actions([:report])
  end

  actions do
    defaults([:read])

    create :open do
      accept([:id, :agent_id, :channel_id, :created_at, :updated_at])
    end

    update :report do
      accept([:last_post_id, :last_version, :caught_up, :incomplete_reason, :checked_at, :updated_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:agent_id, :string, allow_nil?: false, public?: true)
    attribute(:channel_id, :string, allow_nil?: false, public?: true)
    attribute(:last_post_id, :string, public?: true)
    attribute(:last_version, :integer, default: 0, allow_nil?: false, public?: true)
    attribute(:caught_up, :boolean, default: false, allow_nil?: false, public?: true)
    attribute(:incomplete_reason, :string, public?: true)
    attribute(:checked_at, :utc_datetime_usec, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: false)
  end

  identities do
    identity(:coverage_key, [:agent_id, :channel_id])
  end
end
