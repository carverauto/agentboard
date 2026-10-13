defmodule Agentboard.SeatSupply.Host do
  @moduledoc "Captain-enrolled fleet host: launch cap and the SHA-256 of its token. Never use Operations.public/1 on it."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("fleet_hosts")
    repo(Agentboard.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update]) do
      authorize_if(actor_attribute_equals(:fleet_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :enroll do
      accept([
        :host_id,
        :token_hash,
        :launch_cap,
        :revision,
        :changed_by,
        :created_at,
        :updated_at
      ])
    end

    update :change do
      accept([:token_hash, :launch_cap, :revision, :changed_by, :updated_at])
    end
  end

  attributes do
    attribute(:host_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:token_hash, :string, allow_nil?: false, sensitive?: true)
    attribute(:launch_cap, :integer, allow_nil?: false, public?: true)
    attribute(:revision, :integer, allow_nil?: false, constraints: [min: 1], public?: true)
    attribute(:changed_by, :string, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
