defmodule Agentboard.Delivery.PullRequest do
  @moduledoc "One canonical GitHub PR identity; inventory does not imply observed or passing CI."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("delivery_pull_requests")
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
      accept([:id, :owner, :repo, :number, :url, :created_at])
    end
  end

  identities do
    identity(:github_pr, [:owner, :repo, :number])
  end

  relationships do
    has_one :poll_state, Agentboard.Delivery.PollState do
      destination_attribute(:id)
    end

    has_many :task_links, Agentboard.Delivery.TaskLink do
      destination_attribute(:pull_request_id)
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:owner, :string, allow_nil?: false, public?: true)
    attribute(:repo, :string, allow_nil?: false, public?: true)
    # GitHub URLs previously accepted arbitrary positive decimal identifiers.
    # Keep their exact decimal representation rather than imposing a bigint limit.
    attribute(:number, :string, allow_nil?: false, public?: true)
    attribute(:url, :string, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
