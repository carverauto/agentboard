defmodule Agentboard.Mattermost.Outbox do
  @moduledoc "Durable lifecycle delivery intents. Uniqueness is logical (source intent), not numeric; late commits and restarted fan-out select by pending state."
  use Ash.Resource,
    domain: Agentboard.Mattermost,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("mattermost_outbox")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_actions([:claim, :mark_sent, :mark_uncertain, :mark_failed, :defer])
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    ignore_actions([:claim, :mark_sent, :mark_uncertain, :mark_failed, :defer])
  end

  actions do
    defaults([:read])

    create :capture do
      accept([
        :id,
        :source,
        :source_key,
        :source_version,
        :task_id,
        :event_id,
        :destination,
        :routing_revision,
        :state,
        :generation,
        :claim_run_id,
        :next_eligible_at,
        :event_marker,
        :payload,
        :last_error,
        :created_at,
        :updated_at
      ])
    end

    update :claim do
      accept([:claim_run_id, :next_eligible_at, :attempts])
      change(set_attribute(:state, "claimed"))
    end

    update :mark_sent do
      accept([:claim_run_id, :remote_post_id, :remote_root_id, :updated_at])
      change(set_attribute(:state, "sent"))
      change(set_attribute(:uncertain_reason, nil))
      change(set_attribute(:last_error, nil))
    end

    update :mark_uncertain do
      accept([:claim_run_id, :uncertain_reason, :last_error, :updated_at])
      change(set_attribute(:state, "uncertain"))
    end

    update :mark_failed do
      accept([:claim_run_id, :last_error, :next_eligible_at, :updated_at])
      change(set_attribute(:state, "failed"))
    end

    update :defer do
      accept([:claim_run_id, :next_eligible_at, :last_error, :updated_at])
      change(set_attribute(:state, "pending"))
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:source, :string, allow_nil?: false, public?: true)
    attribute(:source_key, :string, allow_nil?: false, public?: true)
    attribute(:source_version, :integer, default: 1, allow_nil?: false, public?: true)
    attribute(:task_id, :string, public?: true)
    attribute(:event_id, :integer, public?: true)
    attribute(:destination, :string, allow_nil?: false, public?: true)
    attribute(:routing_revision, :integer, default: 1, allow_nil?: false, public?: true)
    attribute(:state, :string, default: "pending", allow_nil?: false, public?: true)
    attribute(:generation, :integer, default: 0, allow_nil?: false, public?: true)
    attribute(:claim_run_id, :uuid, public?: true)
    attribute(:next_eligible_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:event_marker, :string, allow_nil?: false, public?: true)
    attribute(:payload, :map, default: %{}, allow_nil?: false, public?: true)
    attribute(:remote_post_id, :string, public?: true)
    attribute(:remote_root_id, :string, public?: true)
    attribute(:uncertain_reason, :string, public?: true)
    attribute(:last_error, :string, public?: true)
    attribute(:attempts, :integer, default: 0, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: false)
  end

  identities do
    identity(:source_intent, [:source, :source_key])
  end
end
