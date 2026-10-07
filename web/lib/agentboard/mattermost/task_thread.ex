defmodule Agentboard.Mattermost.TaskThread do
  @moduledoc "One durable root-post mapping per task. Duplicate roots are flagged, never hidden."
  use Ash.Resource,
    domain: Agentboard.Mattermost,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("mattermost_task_threads")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_actions([:mark_rooted, :mark_uncertain])
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    ignore_actions([:mark_rooted, :mark_uncertain])
  end

  actions do
    defaults([:read])

    create :ensure do
      accept([:task_id, :channel_id, :routing_revision, :created_at, :updated_at])
    end

    update :mark_rooted do
      accept([:channel_id, :root_post_id, :expected_marker, :uncertain_reason, :updated_at])
      change(set_attribute(:state, "rooted"))
    end

    update :mark_uncertain do
      accept([:expected_marker, :uncertain_reason, :updated_at])
      change(set_attribute(:state, "uncertain"))
    end
  end

  attributes do
    attribute(:task_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:channel_id, :string, allow_nil?: false, public?: true)
    attribute(:root_post_id, :string, public?: true)
    attribute(:expected_marker, :string, public?: true)
    attribute(:state, :string, default: "pending", allow_nil?: false, public?: true)
    attribute(:uncertain_reason, :string, public?: true)
    attribute(:routing_revision, :integer, default: 1, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: false)
  end
end
