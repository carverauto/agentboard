defmodule Agentboard.Auth.Observation do
  @moduledoc "Secret-free, append-only API attribution evidence."
  use Ash.Resource, domain: Agentboard.Auth, data_layer: AshPostgres.DataLayer

  postgres do
    table("agent_auth_observations")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :outcome,
        :attributed_agent_id,
        :verified_agent_id,
        :method,
        :route,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:outcome, :string, allow_nil?: false)
    attribute(:attributed_agent_id, :string)
    attribute(:verified_agent_id, :string)
    attribute(:method, :string, allow_nil?: false)
    attribute(:route, :string, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
