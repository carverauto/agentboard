defmodule Agentboard.Mattermost.ConversationIdentity do
  @moduledoc "Explicit stable-agent to Mattermost-user mapping. Sender attribution derives from the authenticated mapping, never from a mutable handle or message text."
  use Ash.Resource,
    domain: Agentboard.Mattermost,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("conversation_identities")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_actions([:note_verified])
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    ignore_actions([:note_verified])
  end

  actions do
    defaults([:read])

    create :enroll do
      accept([:agent_id, :mm_user_id, :mm_username, :credential_ref, :created_at, :updated_at])
    end

    update :note_verified do
      accept([:membership_verified_at, :mm_username, :last_error, :updated_at])
      change(set_attribute(:status, "enrolled"))
    end

    update :suspend do
      accept([:last_error, :updated_at])
      change(set_attribute(:status, "suspended"))
    end

    update :revoke do
      accept([:last_error, :updated_at])
      change(set_attribute(:status, "revoked"))
    end

    update :rename do
      accept([:mm_username, :updated_at])
    end
  end

  attributes do
    attribute(:agent_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:mm_user_id, :string, allow_nil?: false, public?: true)
    attribute(:mm_username, :string, public?: true)
    attribute(:status, :string, default: "enrolled", allow_nil?: false, public?: true)
    attribute(:credential_ref, :string, public?: true)
    attribute(:membership_verified_at, :utc_datetime_usec, public?: true)
    attribute(:last_error, :string, public?: true)
    attribute(:routing_revision, :integer, default: 1, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: false)
  end

  identities do
    identity(:mm_user, [:mm_user_id])
  end
end
