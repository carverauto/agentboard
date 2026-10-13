defmodule Agentboard.Intake.Item do
  @moduledoc """
  One filed card and, when requested, its GitHub issue outbox intent.

  `issue_state` is `none` for card-only items. Issue items move
  `pending -> creating -> created`; definitive rejections and ambiguous
  marker matches park as `uncertain` with a reason until the filer or captain
  reconciles or abandons them. Imported items link an existing issue and
  start as `created` with reason `imported`. Claims are fenced by `generation` and
  `claim_run_id`, so a stale worker cannot overwrite a newer outcome.
  """
  use Ash.Resource,
    domain: Agentboard.Intake,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("intake_items")
    repo(Agentboard.Repo)
  end

  actions do
    defaults([:read])

    create :file do
      accept([
        :id,
        :request_id,
        :position,
        :task_id,
        :repository,
        :issue,
        :issue_state,
        :next_attempt_at,
        :created_at,
        :updated_at
      ])
    end

    # A card for an existing issue. The issue is already there, so the item
    # starts terminal (`created`, reason `imported`) and never enters the
    # outbox.
    create :import do
      accept([
        :id,
        :request_id,
        :position,
        :task_id,
        :repository,
        :issue,
        :issue_state,
        :issue_url,
        :issue_number,
        :reason,
        :resolved_at,
        :created_at,
        :updated_at
      ])
    end

    # Fenced outbox outcome written by the issue worker after the HTTP call.
    update :settle do
      accept([
        :issue_state,
        :issue_url,
        :issue_number,
        :duplicate_issue_urls,
        :reason,
        :last_error,
        :next_attempt_at,
        :resolved_at,
        :updated_at
      ])

      change(set_attribute(:claim_run_id, nil))
      change(set_attribute(:claimed_at, nil))
    end

    update :cancel do
      accept([:issue_state, :cancelled_at, :cancelled_by, :next_attempt_at, :updated_at])
    end

    # Explicit filer/captain decision on an unresolved issue intent.
    update :resolve do
      accept([
        :issue_state,
        :duplicate_issue_urls,
        :reason,
        :last_error,
        :next_attempt_at,
        :resolved_at,
        :updated_at
      ])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:request_id, :uuid, allow_nil?: false, public?: true)
    attribute(:position, :integer, allow_nil?: false, public?: true)
    attribute(:task_id, :string, allow_nil?: false, public?: true)
    attribute(:repository, :string, allow_nil?: false, public?: true)
    attribute(:issue, :boolean, allow_nil?: false, public?: true)
    attribute(:issue_state, :string, allow_nil?: false, public?: true)
    attribute(:issue_url, :string, public?: true)
    attribute(:issue_number, :integer, public?: true)

    attribute(:duplicate_issue_urls, {:array, :string},
      default: [],
      allow_nil?: false,
      public?: true
    )

    attribute(:reason, :string, public?: true)
    attribute(:last_error, :string, public?: true)
    attribute(:attempts, :integer, default: 0, allow_nil?: false, public?: true)
    attribute(:first_attempt_at, :utc_datetime_usec, public?: true)
    attribute(:generation, :integer, default: 0, allow_nil?: false, public?: true)
    attribute(:claim_run_id, :uuid, public?: true)
    attribute(:claimed_at, :utc_datetime_usec, public?: true)
    attribute(:next_attempt_at, :utc_datetime_usec, public?: true)
    attribute(:cancelled_at, :utc_datetime_usec, public?: true)
    attribute(:cancelled_by, :string, public?: true)
    attribute(:resolved_at, :utc_datetime_usec, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
