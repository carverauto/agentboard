defmodule Agentboard.Wake.Intent do
  @moduledoc "Audited wake intent; source handling and native custody stay with their owners."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("wake_intents")
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
      authorize_if(actor_attribute_equals(:wake_internal, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :recipient_id,
        :repo,
        :reason,
        :source_kind,
        :source_id,
        :source_version,
        :reason_hash,
        :task_id,
        :source_ref,
        :cooperation_event_id,
        :delivery_id,
        :state,
        :reason_code,
        :revision,
        :created_at,
        :updated_at
      ])
    end

    update :change do
      accept([:cooperation_event_id, :delivery_id, :state, :reason_code, :revision, :updated_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:recipient_id, :string, allow_nil?: false)
    attribute(:repo, :string, allow_nil?: false)
    attribute(:reason, :string, allow_nil?: false)
    attribute(:source_kind, :string, allow_nil?: false)
    attribute(:source_id, :string, allow_nil?: false)
    attribute(:source_version, :string, allow_nil?: false)
    attribute(:reason_hash, :string, allow_nil?: false)
    attribute(:task_id, :string, allow_nil?: true)
    attribute(:source_ref, :map, allow_nil?: false)
    attribute(:cooperation_event_id, :uuid, allow_nil?: true)
    attribute(:delivery_id, :uuid, allow_nil?: true)
    attribute(:state, :string, allow_nil?: false)
    attribute(:reason_code, :string, allow_nil?: true)
    attribute(:revision, :integer, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
