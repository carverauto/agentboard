defmodule Agentboard.Board.Resources.Message do
  @moduledoc "Existing messages records; migrations retain their original table and constraints."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("messages")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_actions([:create])
    ignore_attributes([:created_at, :updated_at])
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
        :sender_id,
        :model,
        :harness,
        :recipient_id,
        :task_id,
        :body,
        :kind,
        :created_at,
        :read_at,
        :read_model,
        :read_harness
      ])
    end

    update :acknowledge do
      accept([:read_at, :read_model, :read_harness])
    end
  end

  validations do
    validate(attribute_in(:kind, ~w(note task_order)))
  end

  attributes do
    attribute(:kind, :string, default: "note", allow_nil?: false, public?: true)

    attribute :id, :integer do
      public?(true)
      allow_nil?(false)
      primary_key?(true)
      generated?(true)
    end

    attribute :sender_id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :model, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :harness, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :recipient_id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :task_id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :body, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :created_at, :utc_datetime_usec do
      public?(true)
      allow_nil?(false)
    end

    attribute :read_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :read_model, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :read_harness, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end
  end
end
