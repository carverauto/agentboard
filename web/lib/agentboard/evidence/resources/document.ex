defmodule Agentboard.Evidence.Resources.Document do
  @moduledoc "Existing task_documents records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Evidence, data_layer: AshPostgres.DataLayer

  postgres do
    table "task_documents"
    repo Agentboard.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    attribute :id, :integer do
      public? true
      allow_nil? false
      primary_key? true
      generated? true
    end

    attribute :task_id, :string do
      public? true
      allow_nil? false
    end

    attribute :source_agent_id, :string do
      public? true
      allow_nil? false
    end

    attribute :model, :string do
      public? true
      allow_nil? false
    end

    attribute :harness, :string do
      public? true
      allow_nil? false
    end

    attribute :kind, :string do
      public? true
      allow_nil? false
    end

    attribute :title, :string do
      public? true
      allow_nil? false
    end

    attribute :html, :string do
      public? true
      allow_nil? false
      select_by_default? false
      sensitive? true
    end

    attribute :digest, :string do
      public? true
      allow_nil? false
    end

    attribute :pr_url, :string do
      public? true
    end

    attribute :source_revision, :string do
      public? true
    end

    attribute :proposal_name, :string do
      public? true
    end

    attribute :created_at, :utc_datetime_usec do
      public? true
      allow_nil? false
    end

  end
end
