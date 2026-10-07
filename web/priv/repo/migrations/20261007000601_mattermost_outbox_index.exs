defmodule Agentboard.Repo.Migrations.MattermostOutboxIndex do
  @moduledoc "Rename the outbox source-intent index to the Ash-expected name so replays conflict cleanly instead of raising."
  use Ecto.Migration

  def up do
    drop(index(:mattermost_outbox, [:source, :source_key], name: :mattermost_outbox_source_uniq))

    create(
      unique_index(:mattermost_outbox, [:source, :source_key],
        name: :mattermost_outbox_source_source_key_index
      )
    )
  end

  def down, do: raise("Retain bridge outbox evidence; roll back a schema-compatible image")
end
