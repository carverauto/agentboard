defmodule Agentboard.Delivery.CISnapshot do
  @moduledoc "Immutable bounded current-head observation, not an assertion of repository policy compliance."
  use Ash.Resource, domain: Agentboard.Delivery, data_layer: AshPostgres.DataLayer

  postgres do
    table("delivery_ci_snapshots")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :pull_request_id,
        :generation,
        :observed_at,
        :head_sha,
        :base_sha,
        :lifecycle,
        :ci_state,
        :payload
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:pull_request_id, :string, allow_nil?: false)
    attribute(:generation, :integer, allow_nil?: false, constraints: [min: 1])
    attribute(:observed_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:head_sha, :string, allow_nil?: false)
    attribute(:base_sha, :string, allow_nil?: false)
    attribute(:lifecycle, :string, allow_nil?: false)
    attribute(:ci_state, :string, allow_nil?: false)
    attribute(:payload, :map, allow_nil?: false)
  end
end

