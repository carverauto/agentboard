defmodule Agentboard.Cooperation.Subscription do
  use Ash.Resource,
    domain: Agentboard.Cooperation,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events, AshPaperTrail.Resource]

  postgres do
    table("cooperation_subscriptions")
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

  actions do
    defaults([:read])

    create :record do
      accept([:id, :host_id, :repos, :model, :harness, :paused, :revoked, :enrolled_at])
    end

    update :change do
      accept([:host_id, :repos, :model, :harness, :paused, :revoked, :enrolled_at])
    end
  end

  attributes do
    attribute(:id, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:host_id, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:repos, {:array, :string}, allow_nil?: false)
    attribute(:model, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

    attribute(:harness, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:paused, :boolean, allow_nil?: false)
    attribute(:revoked, :boolean, allow_nil?: false)
    attribute(:enrolled_at, :utc_datetime_usec, allow_nil?: false)
  end
end
