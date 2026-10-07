defmodule Agentboard.Delivery.ProviderBudget do
  @moduledoc "Operational provider admission, shared across replicas; no credentials or audit body."
  use Ash.Resource, domain: Agentboard.Delivery, data_layer: AshPostgres.DataLayer

  postgres do
    table("delivery_provider_budgets")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    update :consume do
      accept([:remaining, :reset_at])
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false)
    attribute(:capacity, :integer, allow_nil?: false, constraints: [min: 1, max: 1000])
    attribute(:remaining, :integer, allow_nil?: false, constraints: [min: 0])
    attribute(:reset_at, :utc_datetime_usec, allow_nil?: false)
  end
end
