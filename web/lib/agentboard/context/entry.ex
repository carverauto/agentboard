defmodule Agentboard.Context.Entry do
  use Ash.Resource, domain: Agentboard.Context, data_layer: AshPostgres.DataLayer

  postgres do
    table("context_entries")
    repo(Agentboard.Repo)
    identity_index_names(author_key: "context_entries_author_key")
  end

  actions do
    defaults([:read])

    create :publish do
      accept([
        :entry_key,
        :repo,
        :task_id,
        :pr_url,
        :source_revision,
        :kind,
        :summary,
        :detail,
        :evidence_urls,
        :digest
      ])

      change(Agentboard.Context.Stamp)
    end
  end

  attributes do
    attribute(:id, :integer,
      primary_key?: true,
      generated?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:entry_key, :string, allow_nil?: false, public?: true)
    attribute(:repo, :string, allow_nil?: false, public?: true)
    attribute(:task_id, :string, public?: true)
    attribute(:pr_url, :string, public?: true)
    attribute(:source_revision, :string, public?: true)
    attribute(:kind, :string, allow_nil?: false, public?: true)
    attribute(:summary, :string, allow_nil?: false, public?: true, constraints: [trim?: false])

    attribute(:detail, :string,
      allow_nil?: false,
      default: "",
      select_by_default?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:evidence_urls, {:array, :string}, default: [], allow_nil?: false, public?: true)
    attribute(:source_agent_id, :string, allow_nil?: false, public?: true)
    attribute(:model, :string, allow_nil?: false, public?: true)
    attribute(:harness, :string, allow_nil?: false, public?: true)
    attribute(:digest, :string, allow_nil?: false, select_by_default?: false)
    attribute(:search_text, :string, generated?: true, select_by_default?: false)
    create_timestamp(:created_at, type: :utc_datetime_usec, public?: true)
  end

  calculations do
    calculate :bm25_score,
              :float,
              expr(
                fragment("? <@> to_bm25query(?, 'context_entries_bm25')", search_text, ^arg(:q))
              ) do
      argument(:q, :string, allow_nil?: false)
      public?(true)
    end
  end

  identities do
    identity(:author_key, [:source_agent_id, :entry_key])
  end
end

