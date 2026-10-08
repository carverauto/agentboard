defmodule Agentboard.Recovery.Episode do
  @moduledoc "Audited recovery checkpoint; no host delivery or production activation."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("recovery_episodes")
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
      authorize_if(actor_attribute_equals(:recovery_internal, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :agent_id,
        :host_id,
        :repo,
        :enrollment_revision,
        :binding_epoch,
        :session_id,
        :lease_id,
        :last_heartbeat_at,
        :policy_id,
        :policy_version,
        :policy_snapshot,
        :task_ids,
        :decision_ids,
        :state,
        :reason,
        :attempt_number,
        :budget_used,
        :attempt_id,
        :attempt_budget_counted,
        :reserved_at,
        :deadline_at,
        :next_attempt_at,
        :new_binding_epoch,
        :new_session_id,
        :heartbeat_at,
        :isolation_verified,
        :canonical_check_in_complete,
        :last_host_result,
        :reservations_allowed,
        :escalation_key,
        :created_at,
        :updated_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, allow_nil?: false, primary_key?: true)
    attribute(:agent_id, :string, allow_nil?: false)
    attribute(:host_id, :string, allow_nil?: false)
    attribute(:repo, :string, allow_nil?: false)
    attribute(:enrollment_revision, :integer, allow_nil?: false)
    attribute(:binding_epoch, :integer, allow_nil?: false)
    attribute(:session_id, :string, allow_nil?: false)
    attribute(:lease_id, :string, allow_nil?: false)
    attribute(:last_heartbeat_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:policy_id, :string, allow_nil?: false)
    attribute(:policy_version, :integer, allow_nil?: false)
    attribute(:policy_snapshot, :map, allow_nil?: false)
    attribute(:task_ids, {:array, :string}, allow_nil?: false)
    attribute(:decision_ids, {:array, :uuid}, allow_nil?: false)
    attribute(:state, :string, allow_nil?: false)
    attribute(:reason, :string, allow_nil?: false)
    attribute(:attempt_number, :integer, allow_nil?: false)
    attribute(:budget_used, :integer, allow_nil?: false)
    attribute(:attempt_id, :uuid, allow_nil?: true)
    attribute(:attempt_budget_counted, :boolean, allow_nil?: false)
    attribute(:reserved_at, :utc_datetime_usec, allow_nil?: true)
    attribute(:deadline_at, :utc_datetime_usec, allow_nil?: true)
    attribute(:next_attempt_at, :utc_datetime_usec, allow_nil?: true)
    attribute(:new_binding_epoch, :integer, allow_nil?: true)
    attribute(:new_session_id, :string, allow_nil?: true)
    attribute(:heartbeat_at, :utc_datetime_usec, allow_nil?: true)
    attribute(:isolation_verified, :boolean, allow_nil?: false)
    attribute(:canonical_check_in_complete, :boolean, allow_nil?: false)
    attribute(:last_host_result, :string, allow_nil?: true)
    attribute(:reservations_allowed, :boolean, allow_nil?: false)
    attribute(:escalation_key, :string, allow_nil?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
