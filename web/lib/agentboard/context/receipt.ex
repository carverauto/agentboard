defmodule Agentboard.Context.Receipt do
  use Ash.Resource, domain: Agentboard.Context, data_layer: AshPostgres.DataLayer

  postgres do
    table("context_receipts")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :acknowledge do
      accept([:entry_id])
      change(Agentboard.Context.Stamp)
    end
  end

  attributes do
    attribute(:entry_id, :integer, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:source_agent_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:model, :string, allow_nil?: false, public?: true)
    attribute(:harness, :string, allow_nil?: false, public?: true)
    create_timestamp(:created_at, type: :utc_datetime_usec, public?: true)
  end
end

