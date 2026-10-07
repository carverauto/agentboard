defmodule Agentboard.Delivery.TaskLink do
  @moduledoc "Immutable first submission of a PR by a task; later ownership changes cannot rewrite attribution."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("delivery_task_links")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :task_id,
        :pull_request_id,
        :submitted_by_id,
        :model,
        :harness,
        :source_event_id,
        :attribution,
        :linked_at,
        :recorded_at
      ])
    end
  end

  identities do
    identity(:task_pr, [:task_id, :pull_request_id])
  end

  attributes do
    attribute(:id, :integer,
      primary_key?: true,
      generated?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:task_id, :string, allow_nil?: false, public?: true)
    attribute(:pull_request_id, :string, allow_nil?: false, public?: true)
    attribute(:submitted_by_id, :string, public?: true)
    attribute(:model, :string, public?: true)
    attribute(:harness, :string, public?: true)
    attribute(:source_event_id, :integer, public?: true)
    attribute(:attribution, :string, allow_nil?: false, public?: true)
    attribute(:linked_at, :utc_datetime_usec, public?: true)
    attribute(:recorded_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end

