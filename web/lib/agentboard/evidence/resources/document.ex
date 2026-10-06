defmodule Agentboard.Evidence.Resources.Document do
  @moduledoc "Existing task_documents records; migrations retain their original table and constraints."
  use Ash.Resource,
    domain: Agentboard.Evidence,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("task_documents")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([
      :read,
      create: [
        :task_id,
        :source_agent_id,
        :model,
        :harness,
        :kind,
        :title,
        :html,
        :digest,
        :pr_url,
        :source_revision,
        :proposal_name,
        :created_at
      ]
    ])
  end

  attributes do
    attribute :id, :integer do
      public?(true)
      allow_nil?(false)
      primary_key?(true)
      generated?(true)
    end

    attribute :task_id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :source_agent_id, :string do
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

    attribute :kind, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :title, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :html, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
      select_by_default?(false)
      sensitive?(true)
    end

    attribute :digest, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :pr_url, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :source_revision, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :proposal_name, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :created_at, :utc_datetime_usec do
      public?(true)
      allow_nil?(false)
    end
  end
end

