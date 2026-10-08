defmodule Agentboard.Recovery.Attempt do
  @moduledoc "Audited recovery checkpoint; no host delivery or production activation."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("recovery_attempts")
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
      authorize_if(actor_attribute_equals(:recovery_internal, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :episode_id,
        :number,
        :intent_key,
        :status,
        :reason,
        :reserved_at,
        :updated_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, allow_nil?: false, primary_key?: true)
    attribute(:episode_id, :uuid, allow_nil?: false)
    attribute(:number, :integer, allow_nil?: false)
    attribute(:intent_key, :string, allow_nil?: false)
    attribute(:status, :string, allow_nil?: false)
    attribute(:reason, :string, allow_nil?: false)
    attribute(:reserved_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
