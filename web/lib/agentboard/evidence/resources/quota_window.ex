defmodule Agentboard.Evidence.Resources.QuotaWindow do
  @moduledoc "Existing quota_windows records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Evidence, data_layer: AshPostgres.DataLayer

  postgres do
    table "quota_windows"
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

    attribute :window_id, :string do
      public? true
      allow_nil? false
    end

    attribute :data, :map do
      public? true
      allow_nil? false
    end

  end
end
