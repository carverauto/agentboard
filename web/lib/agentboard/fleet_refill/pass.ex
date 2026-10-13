defmodule Agentboard.FleetRefill.Pass do
  @moduledoc "Latest refill pass per fleet: would-assign pairs in dry_run, assigned pairs in live."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("fleet_refill_passes")
    repo(Agentboard.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update]) do
      authorize_if(actor_attribute_equals(:fleet_refill, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([:fleet_id, :mode, :pairs, :returned, :passed_at])
    end

    update :replace do
      accept([:mode, :pairs, :returned, :passed_at])
    end
  end

  attributes do
    attribute(:fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:mode, :string, allow_nil?: false, public?: true)
    attribute(:pairs, {:array, :map}, allow_nil?: false, public?: true)
    attribute(:returned, :integer, allow_nil?: false, public?: true)
    attribute(:passed_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
