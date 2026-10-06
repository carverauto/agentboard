defmodule Agentboard.Housekeeping.Policy do
  use Ash.Resource,
    domain: Agentboard.Housekeeping,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events, AshOban]

  postgres do
    table("archive_policy")
    repo(Agentboard.Repo)
  end

  paper_trail do
    change_tracking_mode(:full_diff)
    store_action_name?(true)
  end

  events do
    event_log(Agentboard.Housekeeping.Event)
  end

  oban do
    scheduled_actions do
      schedule :archive_sweep, "* * * * *" do
        action(:sweep)
        queue(:housekeeping)
        max_attempts(5)
        worker_module_name(Agentboard.Housekeeping.ArchiveSweep)
        default_actor(%{role: :system, id: "archive-scheduler"})
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:update) do
      authorize_if(actor_attribute_equals(:role, :captain))
      authorize_if(actor_attribute_equals(:role, :system))
    end

    policy action(:sweep) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  actions do
    defaults([
      :read,
      update: [
        :enabled,
        :retention_days,
        :interval_hours,
        :next_run_at,
        :last_run_at,
        :last_archived_count,
        :revision,
        :changed_by
      ]
    ])

    action :sweep, :map do
      run(fn _input, context -> Agentboard.Housekeeping.sweep(context.actor) end)
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:enabled, :boolean, allow_nil?: false, public?: true)

    attribute(:retention_days, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 3650],
      public?: true
    )

    attribute(:interval_hours, :integer, allow_nil?: false, public?: true)
    attribute(:next_run_at, :utc_datetime_usec, public?: true)
    attribute(:last_run_at, :utc_datetime_usec, public?: true)
    attribute(:last_archived_count, :integer, allow_nil?: false, public?: true)
    attribute(:revision, :integer, allow_nil?: false, constraints: [min: 1], public?: true)
    attribute(:changed_by, :string, allow_nil?: false, public?: true)
  end

  validations do
    validate(attribute_in(:interval_hours, [1, 24, 168]))
  end
end

