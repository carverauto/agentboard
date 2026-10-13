defmodule Agentboard.SeatSupply.Intent do
  @moduledoc "One seat-launch intent: a loadout seat, its identity, harness name and desired host. Never argv."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("fleet_launch_intents")
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
      authorize_if(actor_attribute_equals(:seat_supply, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :fleet_id,
        :seat_id,
        :agent_id,
        :harness,
        :host_id,
        :loadout_revision,
        :state,
        :created_at,
        :updated_at
      ])
    end

    update :transition do
      accept([
        :state,
        :reason,
        :workspace_id,
        :tab_id,
        :pane_id,
        :lease_path,
        :updated_at,
        :reserved_at,
        :launched_at,
        :closed_at
      ])
    end
  end

  validations do
    validate(
      attribute_in(
        :state,
        ~w(dry_run pending reserved uncertain launched failed expired superseded closed abandoned)
      )
    )
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:fleet_id, :string, allow_nil?: false, public?: true)
    attribute(:seat_id, :string, allow_nil?: false, public?: true)
    attribute(:agent_id, :string, allow_nil?: false, public?: true)
    attribute(:harness, :string, allow_nil?: false, public?: true)
    attribute(:host_id, :string, allow_nil?: false, public?: true)
    attribute(:loadout_revision, :integer, allow_nil?: false, public?: true)
    attribute(:state, :string, allow_nil?: false, public?: true)
    attribute(:reason, :string, public?: true)
    attribute(:workspace_id, :string, public?: true)
    attribute(:tab_id, :string, public?: true)
    attribute(:pane_id, :string, public?: true)
    attribute(:lease_path, :string, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:reserved_at, :utc_datetime_usec, public?: true)
    attribute(:launched_at, :utc_datetime_usec, public?: true)
    attribute(:closed_at, :utc_datetime_usec, public?: true)
  end
end
