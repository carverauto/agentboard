defmodule Agentboard.Repo.Migrations.MattermostInboundMetadata do
  use Ecto.Migration

  def up do
    create table(:mattermost_inbound_runs, primary_key: false) do
      add(:source, :text, primary_key: true)
      add(:repo, :text, null: false)
      add(:run_id, :uuid, null: false)
      add(:expires_at, :timestamptz, null: false)
      add(:connected, :boolean, null: false, default: false)
      add(:reason, :text, null: false)
    end

    create table(:mattermost_channel_recovery, primary_key: false) do
      add(:source, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:run_id, :uuid, null: false)
      add(:page, :integer, null: false, default: 0)
      add(:history_complete, :boolean, null: false, default: false)
      add(:reason, :text, null: false)
      add(:checked_at, :timestamptz, null: false)
    end

    create table(:mattermost_post_versions, primary_key: false) do
      add(:source, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:post_id, :text, primary_key: true)
      add(:version, :text, primary_key: true)
      add(:user_id, :text, null: false)
      add(:root_id, :text, null: false)
      add(:update_at, :bigint, null: false)
      add(:delete_at, :bigint, null: false)
      add(:observed_at, :timestamptz, null: false)
    end

    create table(:mattermost_inbox, primary_key: false) do
      add(:seq, :bigserial)
      add(:id, :uuid, primary_key: true)
      add(:source, :text, null: false)
      add(:channel_id, :text, null: false)
      add(:post_id, :text, null: false)
      add(:version, :text, null: false)
      add(:worker_id, :text, null: false)
      add(:repo, :text, null: false)
      add(:task_id, :text)
      add(:sender_agent_id, :text)
      add(:msg_id, :text)
      add(:kind, :text, null: false, default: "note")
      add(:created_at, :timestamptz, null: false)
      add(:handled_at, :timestamptz)
      add(:handled_model, :text)
      add(:handled_harness, :text)
    end

    create(unique_index(:mattermost_inbox, [:source, :post_id, :version, :worker_id]))
    create(index(:mattermost_inbox, [:worker_id, :repo, :seq]))
    create(index(:mattermost_inbox, [:worker_id, :handled_at, :id]))
    execute("ALTER TABLE mattermost_inbox ADD CONSTRAINT mattermost_inbox_version_fk FOREIGN KEY (source,channel_id,post_id,version) REFERENCES mattermost_post_versions(source,channel_id,post_id,version)")
    execute("UPDATE board_schema SET version=GREATEST(version,18) WHERE id=1")
  end

  def down, do: raise("Retain pending Mattermost versions and receipts; roll back a schema-compatible image")
end
