defmodule Agentboard.Evidence.Resources.QuotaScope do
  @moduledoc "Existing quota_scopes records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Evidence, data_layer: AshPostgres.DataLayer

  postgres do
    table "quota_scopes"
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

    attribute :observation_id, :integer do
      public? true
      allow_nil? false
    end

    attribute :scope, :string do
      public? true
      allow_nil? false
    end

    attribute :data, :map do
      public? true
      allow_nil? false
    end

  end
end
