defmodule Agentboard.Delivery.PollState do
  @moduledoc "Mutable polling bookkeeping, separate from immutable PR submission evidence."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table("delivery_poll_states")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_actions([:reserve, :defer, :observe, :invalidate_base])
    metadata(:provenance, :map, allow_nil?: false)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
    ignore_actions([:reserve, :defer, :observe, :invalidate_base])
  end

  actions do
    defaults([:read])

    create :enroll do
      accept([:id, :registered_at, :next_poll_at])
    end

    update :reserve do
      accept([:generation, :attempt_id, :lease_expires_at, :last_attempt_at])
    end

    update :defer do
      accept([:attempt_id, :lease_expires_at, :next_poll_at, :last_error])
    end

    update :invalidate_base do
      accept([:generation, :expected_base_sha, :next_poll_at, :last_error])
      change(set_attribute(:attempt_id, nil))
      change(set_attribute(:lease_expires_at, nil))
    end

    update :resume do
      accept([:next_poll_at])
      change(set_attribute(:enabled, true))
      change(filter(expr(enabled == false and lifecycle == "closed")))
    end

    # Explicit operator reconciliation of the legacy SQL-disabled cohort.
    # Advancing generation records even a disabled -> disabled retirement.
    update :reconcile_disabled do
      accept([:enabled, :next_poll_at, :generation])
      argument(:expected_generation, :integer, allow_nil?: false)
      argument(:expected_enabled, :boolean, allow_nil?: false)
      change(set_attribute(:attempt_id, nil))
      change(set_attribute(:lease_expires_at, nil))

      change(
        filter(
          expr(
            enabled == ^arg(:expected_enabled) and generation == ^arg(:expected_generation) and
              (is_nil(lease_expires_at) or lease_expires_at <= fragment("clock_timestamp()"))
          )
        )
      )
    end

    for action <- [:observe_change, :observe, :observe_terminal] do
      update action do
        accept([
          :attempt_id,
          :lease_expires_at,
          :next_poll_at,
          :last_error,
          :ci_state,
          :observed_at,
          :head_sha,
          :base_sha,
          :base_ref,
          :expected_base_sha,
          :snapshot_id,
          :lifecycle
        ])

        if action == :observe_terminal do
          change(set_attribute(:enabled, false))
        end

        argument(:expected_generation, :integer, allow_nil?: false)
        argument(:expected_attempt_id, :uuid, allow_nil?: false)

        change(
          filter(
            expr(
              enabled == true and generation == ^arg(:expected_generation) and
                attempt_id == ^arg(:expected_attempt_id) and
                lease_expires_at > fragment("clock_timestamp()")
            )
          )
        )
      end
    end
  end

  relationships do
    belongs_to :pull_request, Agentboard.Delivery.PullRequest do
      source_attribute(:id)
      define_attribute?(false)
      allow_nil?(false)
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:registered_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:enabled, :boolean, default: true, allow_nil?: false, public?: true)
    attribute(:next_poll_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    attribute(:generation, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true
    )

    attribute(:attempt_id, :uuid, public?: true)
    attribute(:lease_expires_at, :utc_datetime_usec, public?: true)
    attribute(:last_attempt_at, :utc_datetime_usec, public?: true)
    attribute(:last_error, :string, public?: true)
    # Passing still requires the repository-policy stage.
    attribute(:ci_state, :string, default: "unknown", allow_nil?: false, public?: true)
    attribute(:observed_at, :utc_datetime_usec, public?: true)
    attribute(:head_sha, :string, public?: true)
    attribute(:base_sha, :string, public?: true)
    attribute(:base_ref, :string, public?: true)
    attribute(:expected_base_sha, :string, public?: true)
    attribute(:snapshot_id, :uuid, public?: true)
    attribute(:lifecycle, :string, public?: true)
  end
end
