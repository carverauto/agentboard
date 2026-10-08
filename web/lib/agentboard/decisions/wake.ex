defmodule Agentboard.Decisions.Wake do
  @moduledoc "Audited durable captain decision wake."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("decision_wakes")
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

    create :create do
      accept([
        :id,
        :request_id,
        :requester_id,
        :task_id,
        :source_key,
        :route,
        :worker_event_id,
        :worker_id,
        :status,
        :reservation_key,
        :reserved_at,
        :accepted_at,
        :reason,
        :answered_at,
        :created_at,
        :updated_at
      ])
    end

    update :change do
      accept([:status, :reservation_key, :reserved_at, :accepted_at, :reason, :updated_at])
    end
  end

  attributes do
    attribute(:id, :uuid, public?: true, allow_nil?: false, primary_key?: true)
    attribute(:request_id, :uuid, public?: true, allow_nil?: false)

    attribute(:requester_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:task_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:source_key, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:route, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:worker_event_id, :uuid, public?: true)
    attribute(:worker_id, :string, public?: true, constraints: [trim?: false, allow_empty?: true])

    attribute(:status, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:reservation_key, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:reserved_at, :utc_datetime_usec, public?: true)
    attribute(:accepted_at, :utc_datetime_usec, public?: true)
    attribute(:reason, :string, public?: true, constraints: [trim?: false, allow_empty?: true])
    attribute(:answered_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, public?: true, allow_nil?: false)
  end
end
