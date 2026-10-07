defmodule Agentboard.Cooperation.Binding do
  use Ash.Resource,
    domain: Agentboard.Cooperation,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events, AshPaperTrail.Resource]

  postgres do
    table("cooperation_bindings")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    metadata(:provenance, :map, allow_nil?: false)
    ignore_actions([:report, :dispatch])
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    ignore_actions([:report, :dispatch])
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :epoch,
        :generation,
        :session_id,
        :pane_id,
        :adapter,
        :adapter_version,
        :capabilities,
        :connector_state,
        :adapter_state,
        :reason,
        :active_attempt_id,
        :updated_at
      ])
    end

    update :report do
      accept([
        :connector_state,
        :adapter_state,
        :reason,
        :capabilities,
        :reported_at,
        :updated_at
      ])
    end

    update :dispatch do
      accept([:generation, :active_attempt_id, :updated_at])
    end

    update :change do
      accept([
        :epoch,
        :generation,
        :session_id,
        :pane_id,
        :adapter,
        :adapter_version,
        :capabilities,
        :connector_state,
        :adapter_state,
        :reason,
        :active_attempt_id,
        :reported_at,
        :updated_at
      ])
    end
  end

  attributes do
    attribute(:id, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:epoch, :integer, allow_nil?: false)
    attribute(:generation, :integer, allow_nil?: false)
    attribute(:session_id, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:pane_id, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:adapter, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:adapter_version, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:capabilities, :map, allow_nil?: false)

    attribute(:connector_state, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:adapter_state, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:reason, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:active_attempt_id, :uuid)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:reported_at, :utc_datetime_usec)
  end
end
