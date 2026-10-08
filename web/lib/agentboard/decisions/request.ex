defmodule Agentboard.Decisions.Request do
  @moduledoc "Audited durable captain decision request."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("decision_requests")
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
        :task_id,
        :requester_id,
        :kind,
        :gate_ref,
        :question_key,
        :normalization_version,
        :retry_key,
        :expires_at,
        :expires_in,
        :bound_pr,
        :source_type,
        :source_id,
        :promoted_by,
        :question,
        :findings,
        :options,
        :status,
        :recommendation,
        :recommended_by,
        :recommended_at,
        :answer,
        :answered_by,
        :answered_at,
        :on_behalf_of,
        :applied_at,
        :closed_by,
        :close_reason,
        :closed_at,
        :message_id,
        :event_id,
        :created_at,
        :updated_at
      ])
    end

    update :change do
      accept([
        :status,
        :recommendation,
        :recommended_by,
        :recommended_at,
        :answer,
        :answered_by,
        :answered_at,
        :on_behalf_of,
        :applied_at,
        :closed_by,
        :close_reason,
        :closed_at,
        :message_id,
        :event_id,
        :updated_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, public?: true, allow_nil?: false, primary_key?: true)

    attribute(:task_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:requester_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:kind, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:gate_ref, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:question, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:findings, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:question_key, :string, public?: true)
    attribute(:normalization_version, :integer, public?: true)
    attribute(:retry_key, :string, public?: true, constraints: [trim?: false])
    attribute(:expires_in, :integer, public?: true)
    attribute(:expires_at, :utc_datetime_usec, public?: true)
    attribute(:bound_pr, :string, public?: true)
    attribute(:source_type, :string, public?: true)
    attribute(:source_id, :string, public?: true)
    attribute(:promoted_by, :string, public?: true)

    attribute(:options, {:array, :string}, public?: true, allow_nil?: false)

    attribute(:status, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:recommendation, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:recommended_by, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:recommended_at, :utc_datetime_usec, public?: true)
    attribute(:answer, :string, public?: true, constraints: [trim?: false, allow_empty?: true])

    attribute(:answered_by, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:answered_at, :utc_datetime_usec, public?: true)

    attribute(:on_behalf_of, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:applied_at, :utc_datetime_usec, public?: true)
    attribute(:closed_by, :string, public?: true, constraints: [trim?: false, allow_empty?: true])

    attribute(:close_reason, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:closed_at, :utc_datetime_usec, public?: true)
    attribute(:message_id, :integer, public?: true)
    attribute(:event_id, :integer, public?: true)
    attribute(:created_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, public?: true, allow_nil?: false)
  end
end
