defmodule Agentboard.CoordinatorTriage.Disposition do
  @moduledoc "Append-only disposition history, separate from source read and native handling."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("coordinator_triage_dispositions")
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
      accept([:id, :message_id, :sequence, :state, :reason_code, :created_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:message_id, :integer, allow_nil?: false)
    attribute(:sequence, :integer, allow_nil?: false)
    attribute(:state, :string, allow_nil?: false)
    attribute(:reason_code, :string, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
