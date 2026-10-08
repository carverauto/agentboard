defmodule Agentboard.Delivery.PublicationBinding do
  @moduledoc "Retained exact head-repository/branch attribution; a binding is not a write grant."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("delivery_publication_bindings")
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

    create :bind do
      accept([:id, :repo, :head_repo, :branch, :task_id, :bound_by_id, :generation, :created_at])
    end
  end

  identities do
    identity(:head_branch, [:head_repo, :branch])
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:repo, :string, allow_nil?: false, public?: true)
    attribute(:head_repo, :string, allow_nil?: false, public?: true)
    attribute(:branch, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:task_id, :string, allow_nil?: false, public?: true)
    attribute(:bound_by_id, :string, allow_nil?: false, public?: true)
    attribute(:generation, :integer, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
