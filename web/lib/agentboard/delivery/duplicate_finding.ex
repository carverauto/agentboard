defmodule Agentboard.Delivery.DuplicateFinding do
  @moduledoc "Retained possible replay evidence; a finding does not close a PR or decide intent."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("delivery_duplicate_findings")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([:read])
    create :record do
      accept([:id, :merged_pull_request_id, :basis, :snapshot_id, :merged_snapshot_id, :created_at, :notified_recipients])
    end
    update :notify do
      accept([:notified_recipients])
    end
  end

  validations do
    validate(attribute_in(:basis, ~w(head_branch task_submission)))
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:merged_pull_request_id, :string, allow_nil?: false, public?: true)
    attribute(:basis, :string, allow_nil?: false, public?: true)
    attribute(:snapshot_id, :uuid, allow_nil?: false, public?: true)
    attribute(:merged_snapshot_id, :uuid, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:notified_recipients, :map, allow_nil?: false)
  end
end
