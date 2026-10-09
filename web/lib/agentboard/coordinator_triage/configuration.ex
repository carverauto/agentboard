defmodule Agentboard.CoordinatorTriage.Configuration do
  @moduledoc "Captain-owned off/shadow configuration. There is no active mode in this slice."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("coordinator_triage_configuration")
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
      authorize_if(actor_attribute_equals(:triage_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([:id, :mode, :coordinator_id, :revision, :changed_by, :updated_at])
    end

    update :replace do
      accept([:mode, :coordinator_id, :revision, :changed_by, :updated_at])
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false)
    attribute(:mode, :string, allow_nil?: false)
    attribute(:coordinator_id, :string)
    attribute(:revision, :integer, allow_nil?: false)
    attribute(:changed_by, :string, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
