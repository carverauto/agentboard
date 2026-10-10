defmodule Agentboard.Mattermost.DecisionConversations.Intent do
  @moduledoc "Audited metadata-only decision chat intent and retained submission uncertainty."
  use Ash.Resource,
    domain: Agentboard.Mattermost,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table("decision_conversation_intents")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  policies do
    policy(action_type(:read), do: authorize_if(always()))

    policy(action_type([:create, :update]),
      do: authorize_if(actor_attribute_equals(:decision_conversation_internal, true))
    )
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :decision_id,
        :operation,
        :actor_id,
        :credential_id,
        :channel_ids,
        :request_key,
        :request_hash,
        :source,
        :repo,
        :channel_id,
        :root_id,
        :recipient_id,
        :task_id,
        :board_message_id,
        :parent_id,
        :inbox_id,
        :inbox_version,
        :bot_user_id,
        :msg_id,
        :payload_hash,
        :state,
        :reason,
        :created_at,
        :updated_at
      ])
    end

    update :transition do
      accept([
        :state,
        :reason,
        :post_id,
        :post_version,
        :post_metadata,
        :submitted_at,
        :verified_at,
        :updated_at,
        :bot_user_id,
        :duplicate_observed_at,
        :duplicate_post_ids
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:decision_id, :uuid, allow_nil?: false)
    attribute(:credential_id, :uuid, allow_nil?: false)
    attribute(:parent_id, :uuid)
    attribute(:inbox_id, :uuid)
    attribute(:board_message_id, :integer, allow_nil?: false)
    attribute(:channel_ids, {:array, :string}, allow_nil?: false, default: [])

    for name <- [
          :operation,
          :actor_id,
          :request_key,
          :request_hash,
          :source,
          :repo,
          :channel_id,
          :root_id,
          :recipient_id,
          :task_id,
          :msg_id,
          :payload_hash,
          :state
        ] do
      attribute(name, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    end

    for name <- [:inbox_version, :reason, :post_id, :post_version] do
      attribute(name, :string, constraints: [trim?: false, allow_empty?: true])
    end

    attribute(:bot_user_id, :string)
    attribute(:post_metadata, :map)
    attribute(:duplicate_observed_at, :utc_datetime_usec)
    attribute(:duplicate_post_ids, {:array, :string}, default: [], allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:submitted_at, :utc_datetime_usec)
    attribute(:verified_at, :utc_datetime_usec)
  end
end
