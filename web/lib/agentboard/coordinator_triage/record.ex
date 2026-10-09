defmodule Agentboard.CoordinatorTriage.Record do
  @moduledoc "Immutable Message-ID classification and source claims; never a delivery receipt."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("coordinator_inbox_triage")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(actor_attribute_equals(:triage_internal, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :message_id,
        :message_created_at,
        :recipient_id,
        :metadata,
        :classification,
        :capture_mode,
        :configuration_revision,
        :policy_version,
        :provenance,
        :source_verification,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:message_id, :integer, primary_key?: true, allow_nil?: false)
    attribute(:message_created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:recipient_id, :string, allow_nil?: false)
    attribute(:metadata, :map)
    attribute(:classification, :string, allow_nil?: false)
    attribute(:capture_mode, :string, allow_nil?: false)
    attribute(:configuration_revision, :integer, allow_nil?: false)
    attribute(:policy_version, :integer, allow_nil?: false)
    attribute(:provenance, :map, allow_nil?: false)
    attribute(:source_verification, :string, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
