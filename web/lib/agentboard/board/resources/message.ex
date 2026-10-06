defmodule Agentboard.Board.Resources.Message do
  @moduledoc "Existing messages records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Board, data_layer: AshPostgres.DataLayer

  postgres do
    table("messages")
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

    attribute :sender_id, :string do
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

    attribute :recipient_id, :string do
      public?(true)
    end

    attribute :task_id, :string do
      public?(true)
    end

    attribute :body, :string do
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
      public?(true)
    end

    attribute :read_harness, :string do
      public?(true)
    end
  end
end

