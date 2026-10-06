defmodule Agentboard.Board.Resources.Task do
  @moduledoc "Existing tasks records; migrations retain their original table and constraints."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("tasks")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:created_at, :updated_at])
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    update :documentation do
      accept([:revision, :updated_at])
    end

    defaults([:read])

    create :create do
      accept([
        :id,
        :title,
        :description,
        :priority,
        :repo,
        :labels,
        :issue_url,
        :pr_url,
        :status,
        :revision,
        :created_at,
        :updated_at
      ])
    end

    update :assign do
      accept([:status, :assignee_id, :assigner_id, :revision, :updated_at])
    end

    update :claim do
      accept([:status, :assignee_id, :claimed_at, :claim_expires_at, :revision, :updated_at])
    end

    update :renew do
      accept([:claim_expires_at, :revision, :updated_at])
    end

    update :reclaim do
      accept([
        :status,
        :assignee_id,
        :assigner_id,
        :claimed_at,
        :claim_expires_at,
        :revision,
        :updated_at
      ])
    end

    update :release do
      accept([
        :status,
        :assignee_id,
        :assigner_id,
        :claimed_at,
        :claim_expires_at,
        :revision,
        :updated_at
      ])
    end

    update :edit do
      accept([
        :title,
        :description,
        :priority,
        :repo,
        :labels,
        :issue_url,
        :pr_url,
        :revision,
        :updated_at
      ])
    end

    update :link do
      accept([:issue_url, :pr_url, :revision, :updated_at])
    end

    update :update do
      accept([:status, :claimed_at, :claim_expires_at, :revision, :updated_at])
    end

    update :handoff do
      accept([
        :status,
        :assignee_id,
        :assigner_id,
        :claimed_at,
        :claim_expires_at,
        :revision,
        :updated_at
      ])
    end
  end

  relationships do
    has_one :archive, Agentboard.Housekeeping.Archive do
      source_attribute(:id)
      destination_attribute(:id)
      domain(Agentboard.Housekeeping)
    end
  end

  calculations do
    calculate :claim_expired,
              :boolean,
              expr(
                fragment(
                  "? IS NOT NULL AND ? <= clock_timestamp()",
                  claim_expires_at,
                  claim_expires_at
                )
              ) do
      public?(true)
    end

    calculate :archive_revision,
              :integer,
              expr(fragment("coalesce((SELECT revision FROM task_archives WHERE id = ?), 0)", id)) do
      public?(true)
    end
  end

  attributes do
    attribute :id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
      primary_key?(true)
    end

    attribute :title, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :description, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :priority, :integer do
      public?(true)
      allow_nil?(false)
    end

    attribute :repo, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :labels, {:array, :string} do
      public?(true)
      allow_nil?(false)
    end

    attribute :issue_url, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :pr_url, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :status, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
      allow_nil?(false)
    end

    attribute :assignee_id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :assigner_id, :string do
      constraints(trim?: false, allow_empty?: true)
      public?(true)
    end

    attribute :claimed_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :claim_expires_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :revision, :integer do
      public?(true)
      allow_nil?(false)
    end

    attribute :created_at, :utc_datetime_usec do
      public?(true)
      allow_nil?(false)
    end

    attribute :updated_at, :utc_datetime_usec do
      public?(true)
      allow_nil?(false)
    end
  end
end

