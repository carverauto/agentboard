defmodule Agentboard.Delivery.PublicationGrant do
  @moduledoc "Action-scoped publication evidence; no producer may issue repair grants without verified native custody."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("delivery_publication_grants")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :id,
        :binding_id,
        :binding_generation,
        :task_id,
        :holder_id,
        :action,
        :head_sha,
        :default_ref,
        :default_tip_sha,
        :expected_remote_head,
        :order_id,
        :order_revision,
        :repair_task_id,
        :custody_receipt_sha256,
        :publication_nonce,
        :state,
        :expires_at,
        :created_at,
        :updated_at
      ])
    end

    update :change do
      accept([:state, :completed_pr_url, :updated_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:binding_id, :uuid, allow_nil?: false, public?: true)
    attribute(:binding_generation, :integer, allow_nil?: false, public?: true)
    attribute(:task_id, :string, allow_nil?: false, public?: true)
    attribute(:holder_id, :string, allow_nil?: false, public?: true)
    attribute(:action, :string, allow_nil?: false, public?: true)
    attribute(:head_sha, :string, allow_nil?: false, public?: true)
    attribute(:default_ref, :string, public?: true)
    attribute(:default_tip_sha, :string, public?: true)
    attribute(:expected_remote_head, :string, public?: true)
    attribute(:order_id, :uuid, public?: true)
    attribute(:order_revision, :integer, public?: true)
    attribute(:repair_task_id, :string, public?: true)
    attribute(:custody_receipt_sha256, :string, public?: true)
    attribute(:publication_nonce, :uuid, allow_nil?: false, public?: true)
    attribute(:state, :string, allow_nil?: false, public?: true)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:completed_pr_url, :string, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
