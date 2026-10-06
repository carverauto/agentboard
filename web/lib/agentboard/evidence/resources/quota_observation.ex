defmodule Agentboard.Evidence.Resources.QuotaObservation do
  @moduledoc "Existing quota_observations records; migrations retain their original table and constraints."
  use Ash.Resource, domain: Agentboard.Evidence, data_layer: AshPostgres.DataLayer

  postgres do
    table("quota_observations")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read, create: [:report_id, :provider, :account_key, :provider_data]])
  end

  attributes do
    attribute :id, :integer do
      public?(true)
      allow_nil?(false)
      primary_key?(true)
      generated?(true)
    end

    attribute :report_id, :integer do
      public?(true)
      allow_nil?(false)
    end

    attribute :provider, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :account_key, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :provider_data, :map do
      public?(true)
      allow_nil?(false)
    end
  end
end

