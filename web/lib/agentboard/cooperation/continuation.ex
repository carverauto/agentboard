defmodule Agentboard.Cooperation.Continuation do
  @moduledoc "Per-worker idle continuation watermark, explicit disposition and cooldown fence."
  use Ash.Resource,
    domain: Agentboard.Cooperation,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("cooperation_continuations")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    # A suppressed check only moves the next sweep time; it changes no evidence.
    ignore_actions([:defer])
  end

  @fields [
    :progress_event_id,
    :progress_context_id,
    :progress_at,
    :finding_due,
    :disposition,
    :disposition_reason,
    :disposition_key,
    :disposition_at,
    :reminders,
    :reminders_since_progress,
    :no_progress_cooldowns,
    :outages,
    :cooldown_until,
    :cooldown_reason,
    :escalated_at,
    :last_event_id,
    :next_eligible_at,
    :updated_at
  ]

  actions do
    defaults([:read])

    create :record do
      accept([:id | @fields])
    end

    update :change do
      accept(@fields)
    end

    update :defer do
      accept([:next_eligible_at])
    end
  end

  attributes do
    attribute(:id, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:progress_event_id, :integer, allow_nil?: false, default: 0)
    attribute(:progress_context_id, :integer, allow_nil?: false, default: 0)
    attribute(:progress_at, :utc_datetime_usec)
    attribute(:finding_due, :boolean, allow_nil?: false, default: false)
    attribute(:disposition, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:disposition_reason, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:disposition_key, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:disposition_at, :utc_datetime_usec)
    attribute(:reminders, :integer, allow_nil?: false, default: 0)
    attribute(:reminders_since_progress, :integer, allow_nil?: false, default: 0)
    attribute(:no_progress_cooldowns, :integer, allow_nil?: false, default: 0)
    attribute(:outages, :integer, allow_nil?: false, default: 0)
    attribute(:cooldown_until, :utc_datetime_usec)
    attribute(:cooldown_reason, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:escalated_at, :utc_datetime_usec)
    attribute(:last_event_id, :uuid)
    attribute(:next_eligible_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
