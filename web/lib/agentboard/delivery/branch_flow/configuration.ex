defmodule Agentboard.Delivery.BranchFlow.Configuration do
  @moduledoc "Captain-owned ordered display pins with immutable revision history."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("branch_flow_configuration")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update]) do
      authorize_if(actor_attribute_equals(:branch_flow_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([:id, :pinned_repositories, :revision, :changed_by, :updated_at])
    end

    update :replace do
      accept([:pinned_repositories, :revision, :changed_by, :updated_at])
    end
  end

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true)
    attribute(:pinned_repositories, {:array, :string}, allow_nil?: false)
    attribute(:revision, :integer, allow_nil?: false)
    attribute(:changed_by, :string, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
