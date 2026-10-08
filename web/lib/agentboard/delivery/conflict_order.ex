defmodule Agentboard.Delivery.ConflictOrder do
  @moduledoc "Current-base repair episode and retained supersession history; assignments do not transfer native custody."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("delivery_conflict_orders")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :pull_request_id,
        :episode_id,
        :default_ref,
        :default_tip_sha,
        :evaluation_base_ref,
        :evaluation_base_sha,
        :trigger_head_sha,
        :observed_head_sha,
        :snapshot_id,
        :repair_task_id,
        :author_id,
        :recipient_id,
        :revision,
        :state,
        :episode_started_at,
        :deadline_at,
        :selection_reason,
        :escalation_decision_id,
        :created_at,
        :updated_at
      ])
    end

    update :change do
      accept([
        :observed_head_sha,
        :snapshot_id,
        :recipient_id,
        :revision,
        :state,
        :selection_reason,
        :rebaser_id,
        :escalation_decision_id,
        :resolved_at,
        :resolution_snapshot_id,
        :updated_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:pull_request_id, :string, allow_nil?: false, public?: true)
    attribute(:episode_id, :uuid, allow_nil?: false, public?: true)
    attribute(:default_ref, :string, allow_nil?: false, public?: true)
    attribute(:default_tip_sha, :string, allow_nil?: false, public?: true)
    attribute(:evaluation_base_ref, :string, allow_nil?: false, public?: true)
    attribute(:evaluation_base_sha, :string, allow_nil?: false, public?: true)
    attribute(:trigger_head_sha, :string, allow_nil?: false, public?: true)
    attribute(:observed_head_sha, :string, allow_nil?: false, public?: true)
    attribute(:snapshot_id, :uuid, allow_nil?: false, public?: true)
    attribute(:repair_task_id, :string, allow_nil?: false, public?: true)
    attribute(:author_id, :string, public?: true)
    attribute(:recipient_id, :string, public?: true)
    attribute(:revision, :integer, allow_nil?: false, public?: true)
    attribute(:state, :string, allow_nil?: false, public?: true)
    attribute(:episode_started_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:deadline_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:selection_reason, :string, public?: true)
    attribute(:rebaser_id, :string, public?: true)
    attribute(:escalation_decision_id, :uuid, public?: true)
    attribute(:resolved_at, :utc_datetime_usec, public?: true)
    attribute(:resolution_snapshot_id, :uuid, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
