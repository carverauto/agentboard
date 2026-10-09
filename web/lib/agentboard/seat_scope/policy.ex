defmodule Agentboard.SeatScope.Policy do
  @moduledoc "Captain-owned task scope, separate from self-reported identity metadata."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("seat_scopes")
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
      authorize_if(actor_attribute_equals(:availability_admin, true))
    end
  end

  actions do
    defaults([:read])

    create :create_scope do
      accept([
        :agent_id,
        :allowed_repos,
        :required_labels,
        :allowed_labels,
        :revision,
        :changed_by,
        :updated_at
      ])
    end

    update :set_scope do
      accept([
        :allowed_repos,
        :required_labels,
        :allowed_labels,
        :revision,
        :changed_by,
        :updated_at
      ])
    end
  end

  attributes do
    attribute(:agent_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:allowed_repos, {:array, :string}, allow_nil?: false, public?: true)

    attribute(:required_labels, {:array, :string},
      allow_nil?: false,
      constraints: [items: [trim?: false]],
      public?: true
    )

    attribute(:allowed_labels, {:array, :string},
      allow_nil?: false,
      constraints: [items: [trim?: false]],
      public?: true
    )

    attribute(:revision, :integer, allow_nil?: false, constraints: [min: 1], public?: true)
    attribute(:changed_by, :string, allow_nil?: false, public?: true)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
