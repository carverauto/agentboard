defmodule Agentboard.Cooperation.NativeApproval do
  @moduledoc "Immutable captain-approved descriptor; no executable discovery or initialization."
  use Ash.Resource,
    domain: Agentboard.Cooperation,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("cooperation_native_approvals")
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
      authorize_if(actor_attribute_equals(:native_authority_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :worker_id,
        :expected_authority_revision,
        :authority_revision,
        :idempotency_key,
        :manifest,
        :manifest_sha256,
        :approved_by,
        :approved_at
      ])
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:worker_id, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:expected_authority_revision, :integer, allow_nil?: false)
    attribute(:authority_revision, :integer, allow_nil?: false)
    attribute(:idempotency_key, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:manifest, :map, allow_nil?: false)
    attribute(:manifest_sha256, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:approved_by, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:approved_at, :utc_datetime_usec, allow_nil?: false)
  end
end
