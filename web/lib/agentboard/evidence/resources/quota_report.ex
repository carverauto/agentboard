defmodule Agentboard.Evidence.Resources.QuotaReport do
  @moduledoc "Existing quota_reports records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Evidence, data_layer: AshPostgres.DataLayer

  postgres do
    table "quota_reports"
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

    attribute :schema_version, :integer do
      public? true
      allow_nil? false
    end

    attribute :digest, :string do
      public? true
      allow_nil? false
    end

    attribute :generated_at, :utc_datetime_usec do
      public? true
      allow_nil? false
    end

    attribute :ingested_at, :utc_datetime_usec do
      public? true
      allow_nil? false
    end

    attribute :raw, :map do
      public? true
      allow_nil? false
      select_by_default? false
      sensitive? true
    end

  end
end
