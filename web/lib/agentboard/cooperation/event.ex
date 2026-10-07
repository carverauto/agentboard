defmodule Agentboard.Cooperation.Event do
  use Ash.Resource, domain: Agentboard.Cooperation, data_layer: AshPostgres.DataLayer

  postgres do
    table("cooperation_events")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :source_key,
        :kind,
        :repo,
        :task_id,
        :context_id,
        :summary,
        :source_url,
        :priority,
        :audience,
        :route_cursor,
        :routed,
        :created_at
      ])
    end

    update :change do
      accept([
        :source_key,
        :kind,
        :repo,
        :task_id,
        :context_id,
        :summary,
        :source_url,
        :priority,
        :audience,
        :route_cursor,
        :routed,
        :created_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)

    attribute(:source_key, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:kind, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:repo, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:task_id, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:context_id, :integer)

    attribute(:summary, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:source_url, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:priority, :integer, allow_nil?: false)
    attribute(:audience, {:array, :string}, allow_nil?: false)
    attribute(:route_cursor, :integer, allow_nil?: false)
    attribute(:routed, :boolean, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end
end
