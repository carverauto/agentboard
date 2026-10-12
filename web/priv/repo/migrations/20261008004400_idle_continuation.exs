defmodule Agentboard.Repo.Migrations.IdleContinuation do
  use Ecto.Migration

  # One bounded continuation state row per enrolled worker binding. Reminders
  # themselves remain ordinary immutable cooperation events/deliveries; this row
  # only holds the progress watermark, explicit dispositions and cooldown fences.
  def up do
    create table(:cooperation_continuations, primary_key: false) do
      add(:id, references(:cooperation_subscriptions, type: :text, on_delete: :restrict),
        primary_key: true
      )

      add(:progress_event_id, :bigint, null: false, default: 0)
      add(:progress_context_id, :bigint, null: false, default: 0)
      add(:progress_at, :timestamptz)
      add(:finding_due, :boolean, null: false, default: false)
      add(:disposition, :text)
      add(:disposition_reason, :text)
      add(:disposition_key, :text)
      add(:disposition_at, :timestamptz)
      add(:reminders, :bigint, null: false, default: 0)
      add(:reminders_since_progress, :integer, null: false, default: 0)
      add(:no_progress_cooldowns, :integer, null: false, default: 0)
      add(:outages, :integer, null: false, default: 0)
      add(:cooldown_until, :timestamptz)
      add(:cooldown_reason, :text)
      add(:escalated_at, :timestamptz)
      add(:last_event_id, references(:cooperation_events, type: :uuid, on_delete: :restrict))
      add(:next_eligible_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    create(
      constraint(:cooperation_continuations, :continuation_shape,
        check:
          "progress_event_id>=0 AND progress_context_id>=0 AND reminders>=0 AND reminders_since_progress>=0 AND no_progress_cooldowns>=0 AND outages>=0 AND (disposition IS NULL OR disposition IN ('no_new_finding','provider_outage','model_outage','quota_exhausted')) AND (disposition IS NULL) = (disposition_at IS NULL) AND (disposition IS NULL) = (disposition_key IS NULL) AND (disposition_key IS NULL OR octet_length(disposition_key) BETWEEN 1 AND 128) AND (disposition_reason IS NULL OR octet_length(disposition_reason) BETWEEN 1 AND 512) AND (cooldown_until IS NULL) = (cooldown_reason IS NULL) AND (cooldown_reason IS NULL OR cooldown_reason IN ('repeated_no_progress','provider_outage','model_outage','quota_exhausted'))"
      )
    )

    create(index(:cooperation_continuations, [:next_eligible_at, :id]))

    # Progress watermarks read one worker's newest attributed task event.
    create(index(:task_events, [:actor_id, :id]))

    execute("UPDATE board_schema SET version=GREATEST(version,44) WHERE id=1")
  end

  # Code that predates this table never schedules continuation; keep the
  # retained dispositions/cooldown evidence and roll back with compatible code.
  def down, do: raise("Retain idle continuation evidence; use compatible code")
end
