defmodule Agentboard.DecisionPolicy.Ledger do
  @moduledoc "Server decision policy ledger; writes use a verified domain boundary."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("decision_policy_ledger")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update]) do
      authorize_if(actor_attribute_equals(:decision_policy_internal, true))
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :decision_id,
        :policy_id,
        :task_id,
        :gate_ref,
        :policy_version,
        :policy_sha256,
        :source_version,
        :generation,
        :rule_id,
        :answer,
        :answer_sha256,
        :limit_key,
        :day,
        :ci_runs,
        :result,
        :reason,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, allow_nil?: false, primary_key?: true)
    attribute(:decision_id, :uuid, allow_nil?: false)
    attribute(:policy_id, :uuid, allow_nil?: false)
    attribute(:task_id, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:gate_ref, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:policy_version, :integer, allow_nil?: false)
    attribute(:policy_sha256, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:source_version, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:generation, :integer, allow_nil?: false)
    attribute(:rule_id, :string, allow_nil?: true, constraints: [trim?: false])
    attribute(:answer, :string, allow_nil?: true, constraints: [trim?: false])
    attribute(:answer_sha256, :string, allow_nil?: true, constraints: [trim?: false])
    attribute(:limit_key, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:day, :date, allow_nil?: false)
    attribute(:ci_runs, :integer, allow_nil?: false)
    attribute(:result, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:reason, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
