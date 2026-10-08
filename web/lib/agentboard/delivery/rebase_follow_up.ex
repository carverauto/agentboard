defmodule Agentboard.Delivery.RebaseFollowUp do
  @moduledoc "One retained conflict follow-up per canonical PR and head, separate from CI episodes."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("delivery_rebase_follow_ups")
    repo(Agentboard.Repo)
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
        :head_sha,
        :base_sha,
        :snapshot_id,
        :repair_task_id,
        :responsible_id,
        :created_at
      ])
    end

    update :resolve do
      accept([:resolved_at, :resolution_snapshot_id])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:pull_request_id, :string, allow_nil?: false)
    attribute(:head_sha, :string, allow_nil?: false)
    attribute(:base_sha, :string, allow_nil?: false)
    attribute(:snapshot_id, :uuid, allow_nil?: false)
    attribute(:repair_task_id, :string, allow_nil?: false)
    attribute(:responsible_id, :string)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:resolved_at, :utc_datetime_usec)
    attribute(:resolution_snapshot_id, :uuid)
  end
end
