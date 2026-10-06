defmodule Agentboard.Board.Resources.Agent do
  @moduledoc "Existing agents records; migrations retain their original table and constraints."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("agents")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:created_at, :updated_at, :last_heartbeat, :metadata])
    metadata(:provenance, :map, allow_nil?: false)
    ignore_actions([:heartbeat])
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    ignore_actions([:heartbeat])
  end

  actions do
    defaults([:read])

    create :register_new do
      accept([
        :id,
        :name,
        :harness,
        :model,
        :host,
        :capabilities,
        :metadata,
        :reported_status,
        :last_heartbeat,
        :created_at,
        :updated_at,
        :current_task_id
      ])
    end

    update :register do
      accept([
        :name,
        :harness,
        :model,
        :host,
        :capabilities,
        :metadata,
        :reported_status,
        :last_heartbeat,
        :updated_at,
        :current_task_id
      ])
    end

    update :heartbeat do
      accept([
        :name,
        :harness,
        :model,
        :host,
        :capabilities,
        :metadata,
        :reported_status,
        :last_heartbeat,
        :updated_at,
        :current_task_id
      ])
    end
  end

  attributes do
    attribute :id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
      primary_key?(true)
    end

    attribute :name, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :harness, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :model, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :host, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :capabilities, {:array, :string} do
      public?(true)
      allow_nil?(false)
    end

    attribute :metadata, :map do
      sensitive?(true)
      public?(true)
      allow_nil?(false)
    end

    attribute :reported_status, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :last_heartbeat, :utc_datetime_usec do
      public?(true)
    end

    attribute :created_at, :utc_datetime_usec do
      public?(true)
      allow_nil?(false)
    end

    attribute :updated_at, :utc_datetime_usec do
      public?(true)
      allow_nil?(false)
    end

    attribute :current_task_id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end
  end
end

