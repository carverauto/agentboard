defmodule Agentboard.Context.Link do
  use Ash.Resource, domain: Agentboard.Context, data_layer: AshPostgres.DataLayer

  postgres do
    table("context_links")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :publish do
      accept([:entry_id, :target_id, :relation])
    end
  end

  attributes do
    attribute(:entry_id, :integer, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:target_id, :integer, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:relation, :string, primary_key?: true, allow_nil?: false, public?: true)
  end
end

