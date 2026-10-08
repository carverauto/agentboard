defmodule Agentboard.Delivery.WorkflowRun do
  @moduledoc "One retained default-branch workflow obligation per repository/run; webhook bodies and logs are never stored."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("delivery_workflow_runs")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([:read])
    create :queue do
      accept([:id, :repository, :run_id, :requested_at, :next_poll_at])
      upsert?(true)
      upsert_fields([:requested_at, :next_poll_at])
    end
    update :reserve do
      accept([:generation, :lease_expires_at])
    end
    update :observe do
      accept([:workflow_id, :workflow_name, :branch, :head_sha, :run_number, :run_attempt,
        :conclusion, :source_url, :jobs, :responsible_id, :source_tasks, :message_id,
        :failed_at, :resolved_at, :resolution_run_id, :observed_at, :processed_at,
        :next_poll_at, :last_error, :lease_expires_at])
    end
    update :resolve do
      accept([:resolved_at, :resolution_run_id])
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false)
    attribute(:repository, :string, allow_nil?: false)
    attribute(:run_id, :string, allow_nil?: false)
    attribute(:requested_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:next_poll_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:processed_at, :utc_datetime_usec)
    attribute(:observed_at, :utc_datetime_usec)
    attribute(:last_error, :string)
    attribute(:generation, :integer, allow_nil?: false, default: 0)
    attribute(:lease_expires_at, :utc_datetime_usec)
    attribute(:workflow_id, :string)
    attribute(:workflow_name, :string)
    attribute(:branch, :string)
    attribute(:head_sha, :string)
    attribute(:run_number, :integer)
    attribute(:run_attempt, :integer)
    attribute(:conclusion, :string)
    attribute(:source_url, :string)
    attribute(:jobs, {:array, :map}, allow_nil?: false, default: [])
    attribute(:responsible_id, :string)
    attribute(:source_tasks, {:array, :string}, allow_nil?: false, default: [])
    attribute(:message_id, :integer)
    attribute(:failed_at, :utc_datetime_usec)
    attribute(:resolved_at, :utc_datetime_usec)
    attribute(:resolution_run_id, :string)
  end
end

defmodule Agentboard.Delivery.WorkflowHealth do
  @moduledoc "Per-workflow serialization and retained green watermark prevent late failures reopening repaired main builds."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("delivery_workflow_health")
    repo(Agentboard.Repo)
  end
  events do
    event_log(Agentboard.Board.AuditEvent)
  end
  actions do
    defaults([:read])
    create :enroll do
      accept([:id])
      upsert?(true)
      upsert_fields([:id])
    end
    update :green do
      accept([:green_number, :green_attempt, :green_run_id])
    end
  end
  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false)
    attribute(:green_number, :integer, allow_nil?: false, default: 0)
    attribute(:green_attempt, :integer, allow_nil?: false, default: 0)
    attribute(:green_run_id, :string)
  end
end
