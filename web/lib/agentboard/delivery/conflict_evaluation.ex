defmodule Agentboard.Delivery.ConflictEvaluation do
  @moduledoc "Audit-only plan: AshEvents persists evidence; no separate mutable evaluation projection."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshEvents.Events]

  events do
    event_log(Agentboard.Board.AuditEvent)
    create_timestamp(:evaluated_at)
  end

  actions do
    create :record do
      accept([:id, :pull_request_id, :snapshot_id, :facts, :evaluated_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:pull_request_id, :string, allow_nil?: false)
    attribute(:snapshot_id, :uuid, allow_nil?: false)
    attribute(:facts, :map, allow_nil?: false)
    attribute(:evaluated_at, :utc_datetime_usec, allow_nil?: false)
  end
end
