defmodule Agentboard.Wake.Attempt do
  @moduledoc "Audited wake attempt; source handling and native custody stay with their owners."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("wake_attempts")
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
        :intent_id,
        :worker_id,
        :host_id,
        :enrollment_revision,
        :binding_epoch,
        :session_id,
        :adapter_generation,
        :cooperation_attempt_id,
        :idempotency_key,
        :payload_hash,
        :reservation,
        :state,
        :reason_codes,
        :evidence_refs,
        :expires_at,
        :created_at,
        :updated_at
      ])
    end

    update :change do
      accept([:state, :reason_codes, :evidence_refs, :updated_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:intent_id, :uuid, allow_nil?: false)
    attribute(:worker_id, :string, allow_nil?: false)
    attribute(:host_id, :string, allow_nil?: false)
    attribute(:enrollment_revision, :integer, allow_nil?: false)
    attribute(:binding_epoch, :integer, allow_nil?: false)
    attribute(:session_id, :string, allow_nil?: false)
    attribute(:adapter_generation, :string, allow_nil?: false)
    attribute(:cooperation_attempt_id, :uuid, allow_nil?: false)
    attribute(:idempotency_key, :string, allow_nil?: false)
    attribute(:payload_hash, :string, allow_nil?: false)
    attribute(:reservation, :map, allow_nil?: false)
    attribute(:state, :string, allow_nil?: false)
    attribute(:reason_codes, {:array, :string}, allow_nil?: false)
    attribute(:evidence_refs, {:array, :string}, allow_nil?: false)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
