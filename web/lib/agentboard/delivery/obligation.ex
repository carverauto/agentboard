defmodule Agentboard.Delivery.Obligation do
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("delivery_obligations")
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
        :episode,
        :repair_task_id,
        :responsible_id,
        :state,
        :head_sha,
        :snapshot_id,
        :evidence_urls,
        :last_progress_at,
        :blocker,
        :next_reminder_at,
        :reminder_generation,
        :window_at,
        :reminders,
        :escalated_at,
        :resolved_at,
        :created_at
      ])
    end

    update :change do
      accept([
        :pull_request_id,
        :episode,
        :repair_task_id,
        :responsible_id,
        :state,
        :head_sha,
        :snapshot_id,
        :evidence_urls,
        :last_progress_at,
        :blocker,
        :next_reminder_at,
        :reminder_generation,
        :window_at,
        :reminders,
        :escalated_at,
        :resolved_at,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)

    attribute(:pull_request_id, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:episode, :integer, allow_nil?: false)

    attribute(:repair_task_id, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:responsible_id, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:state, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:snapshot_id, :uuid)
    attribute(:evidence_urls, {:array, :string}, allow_nil?: false)

    attribute(:head_sha, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:last_progress_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:blocker, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:next_reminder_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:reminder_generation, :integer, allow_nil?: false)
    attribute(:window_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:reminders, :integer, allow_nil?: false)
    attribute(:escalated_at, :utc_datetime_usec)
    attribute(:resolved_at, :utc_datetime_usec)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
