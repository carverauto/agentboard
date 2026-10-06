defmodule Agentboard.Board.Resources.TaskEvent do
  @moduledoc "Existing task_events records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Board, data_layer: AshPostgres.DataLayer

  postgres do
    table("task_events")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute :id, :integer do
      public?(true)
      allow_nil?(false)
      primary_key?(true)
      generated?(true)
    end

    attribute :task_id, :string do
      public?(true)
      allow_nil?(false)
    end

    attribute :actor_id, :string do
      public?(true)
      allow_nil?(false)
    end

    attribute :model, :string do
      public?(true)
      allow_nil?(false)
    end

    attribute :harness, :string do
      public?(true)
      allow_nil?(false)
    end

    attribute :kind, :string do
      public?(true)
      allow_nil?(false)
    end

    attribute :body, :string do
      public?(true)
    end

    attribute :old_revision, :integer do
      public?(true)
    end

    attribute :new_revision, :integer do
      public?(true)
      allow_nil?(false)
    end

    attribute :data, :map do
      public?(true)
      allow_nil?(false)
    end

    attribute :created_at, :utc_datetime_usec do
      public?(true)
      allow_nil?(false)
    end
  end
end

