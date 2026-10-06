defmodule Agentboard.Board.Resources.Task do
  @moduledoc "Existing tasks records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Board, data_layer: AshPostgres.DataLayer

  postgres do
    table "tasks"
    repo Agentboard.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    attribute :id, :string do
      public? true
      allow_nil? false
      primary_key? true
    end

    attribute :title, :string do
      public? true
      allow_nil? false
    end

    attribute :description, :string do
      public? true
      allow_nil? false
    end

    attribute :priority, :integer do
      public? true
      allow_nil? false
    end

    attribute :repo, :string do
      public? true
    end

    attribute :labels, {:array, :string} do
      public? true
      allow_nil? false
    end

    attribute :issue_url, :string do
      public? true
    end

    attribute :pr_url, :string do
      public? true
    end

    attribute :status, :string do
      public? true
      allow_nil? false
    end

    attribute :assignee_id, :string do
      public? true
    end

    attribute :assigner_id, :string do
      public? true
    end

    attribute :claimed_at, :utc_datetime_usec do
      public? true
    end

    attribute :claim_expires_at, :utc_datetime_usec do
      public? true
    end

    attribute :revision, :integer do
      public? true
      allow_nil? false
    end

    attribute :created_at, :utc_datetime_usec do
      public? true
      allow_nil? false
    end

    attribute :updated_at, :utc_datetime_usec do
      public? true
      allow_nil? false
    end

  end
end
