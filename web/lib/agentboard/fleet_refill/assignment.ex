defmodule Agentboard.FleetRefill.Assignment do
  @moduledoc "One refill assignment and its single task_order, keyed by task ID and assignment revision."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("fleet_refill_assignments")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
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
      accept([
        :id,
        :fleet_id,
        :task_id,
        :agent_id,
        :task_revision,
        :message_id,
        :event_id,
        :state,
        :deadline_at,
        :created_at
      ])
    end

    update :resolve do
      accept([:state, :resolved_at, :resolution_event_id])
    end
  end

  validations do
    validate(attribute_in(:state, ~w(assigned claimed missed superseded)))
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:fleet_id, :string, allow_nil?: false, public?: true)
    attribute(:task_id, :string, allow_nil?: false, public?: true)
    attribute(:agent_id, :string, allow_nil?: false, public?: true)
    attribute(:task_revision, :integer, allow_nil?: false, public?: true)
    attribute(:message_id, :integer, allow_nil?: false, public?: true)
    attribute(:event_id, :integer, allow_nil?: false, public?: true)
    attribute(:state, :string, allow_nil?: false, public?: true)
    attribute(:deadline_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:resolved_at, :utc_datetime_usec, public?: true)
    attribute(:resolution_event_id, :integer, public?: true)
  end
end
