defmodule Agentboard.Intake.Request do
  @moduledoc """
  One accepted intake request. The normalized payload and its digest decide
  whether a repeated request key replays (same digest) or conflicts.
  """
  use Ash.Resource,
    domain: Agentboard.Intake,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("intake_requests")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :file do
      accept([:id, :filer_id, :request_key, :payload_sha256, :payload, :created_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:filer_id, :string, allow_nil?: false, public?: true)
    attribute(:request_key, :string, allow_nil?: false, public?: true)
    attribute(:payload_sha256, :string, allow_nil?: false, public?: true)
    attribute(:payload, :map, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
