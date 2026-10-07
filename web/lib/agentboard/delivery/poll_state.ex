defmodule Agentboard.Delivery.PollState do
  @moduledoc "Mutable polling bookkeeping, separate from immutable PR submission evidence."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("delivery_poll_states")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_actions([:reserve, :defer])
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    ignore_actions([:reserve, :defer])
  end

  actions do
    defaults([:read])

    create :enroll do
      accept([:id, :registered_at, :next_poll_at])
    end

    update :reserve do
      accept([:generation, :attempt_id, :lease_expires_at, :last_attempt_at])
    end

    update :defer do
      accept([:attempt_id, :lease_expires_at, :next_poll_at, :last_error])
    end
  end

  relationships do
    belongs_to :pull_request, Agentboard.Delivery.PullRequest do
      source_attribute(:id)
      define_attribute?(false)
      allow_nil?(false)
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:registered_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:enabled, :boolean, default: true, allow_nil?: false, public?: true)
    attribute(:next_poll_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    attribute(:generation, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true
    )

    attribute(:attempt_id, :uuid, public?: true)
    attribute(:lease_expires_at, :utc_datetime_usec, public?: true)
    attribute(:last_attempt_at, :utc_datetime_usec, public?: true)
    attribute(:last_error, :string, public?: true)
    # No action in this preparatory stage can certify CI or set a provider head.
    attribute(:ci_state, :string, default: "unknown", allow_nil?: false, public?: true)
    attribute(:observed_at, :utc_datetime_usec, public?: true)
    attribute(:head_sha, :string, public?: true)
  end
end
