defmodule Agentboard.Delivery.PollCredit do
  @moduledoc "Durable unused poll credit; charged before I/O, reclaimed on completion or lease expiry."
  use Ash.Resource, domain: Agentboard.Delivery, data_layer: AshPostgres.DataLayer

  postgres do
    table("delivery_poll_credits")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :reserve do
      accept([:id, :pull_request_id, :remaining, :window_end, :expires_at])
    end

    update :spend do
      accept([:remaining])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:pull_request_id, :string, allow_nil?: false)
    attribute(:remaining, :integer, allow_nil?: false, constraints: [min: 0, max: 32])
    attribute(:window_end, :utc_datetime_usec, allow_nil?: false)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false)
  end
end
