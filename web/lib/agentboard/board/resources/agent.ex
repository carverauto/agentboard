defmodule Agentboard.Board.Resources.Agent do
  @moduledoc "Existing agents records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Board, data_layer: AshPostgres.DataLayer

  postgres do
    table("agents")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute :id, :string do
      public?(true)
      allow_nil?(false)
      primary_key?(true)
    end

    attribute :name, :string do
      public?(true)
      allow_nil?(false)
    end

    attribute :harness, :string do
      public?(true)
      allow_nil?(false)
    end

    attribute :model, :string do
      public?(true)
      allow_nil?(false)
    end

    attribute :host, :string do
      public?(true)
    end

    attribute :capabilities, {:array, :string} do
      public?(true)
      allow_nil?(false)
    end

    attribute :metadata, :map do
      public?(true)
      allow_nil?(false)
    end

    attribute :reported_status, :string do
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
      public?(true)
    end
  end
end

