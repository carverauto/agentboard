defmodule Agentboard.Delivery.BaseWatch do
  @moduledoc "Durable branch reservation and invalidation cursor, independent of worker process lifetime."
  use Ash.Resource, domain: Agentboard.Delivery, data_layer: AshPostgres.DataLayer

  postgres do
    table("delivery_base_watches")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :enroll do
      accept([:id, :owner, :repo, :ref, :head_sha, :next_poll_at])
    end

    update :reserve do
      accept([:generation, :attempt_id, :lease_expires_at])
    end

    update :observe do
      accept([
        :head_sha,
        :revision,
        :next_poll_at,
        :last_success_at,
        :last_error,
        :attempt_id,
        :lease_expires_at
      ])
    end

    update :invalidate do
      accept([:invalidated_revision])
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false)
    attribute(:owner, :string, allow_nil?: false)
    attribute(:repo, :string, allow_nil?: false)
    attribute(:ref, :string, allow_nil?: false, constraints: [trim?: false, max_length: 255])
    attribute(:head_sha, :string, allow_nil?: false)
    attribute(:next_poll_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:last_success_at, :utc_datetime_usec)
    attribute(:last_error, :string)
    attribute(:generation, :integer, default: 0, allow_nil?: false)
    attribute(:attempt_id, :uuid)
    attribute(:lease_expires_at, :utc_datetime_usec)
    attribute(:revision, :integer, default: 0, allow_nil?: false)
    attribute(:invalidated_revision, :integer, default: 0, allow_nil?: false)
  end
end
