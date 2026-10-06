defmodule Agentboard.Housekeeping.Archive do
  use Ash.Resource,
    domain: Agentboard.Housekeeping,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("task_archives")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:full_diff)
    store_action_name?(true)
  end

  events do
    event_log(Agentboard.Housekeeping.Event)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update]) do
      authorize_if(actor_attribute_equals(:role, :captain))
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    defaults([
      :read,
      create: [:id, :archived_at, :restored_at, :changed_by, :revision],
      update: [:archived_at, :restored_at, :changed_by, :revision]
    ])
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:archived_at, :utc_datetime_usec, public?: true)
    attribute(:restored_at, :utc_datetime_usec, public?: true)
    attribute(:changed_by, :string, allow_nil?: false, public?: true)
    attribute(:revision, :integer, allow_nil?: false, constraints: [min: 1], public?: true)
  end
end

