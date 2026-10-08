defmodule Agentboard.Repo.Migrations.CaptainWaitingLane do
  use Ecto.Migration

  def up do
    alter table(:decision_requests) do
      add(:question_key, :text)
      add(:normalization_version, :integer)
      add(:retry_key, :text)
      add(:expires_in, :integer)
      add(:expires_at, :timestamptz)
      add(:bound_pr, :text)
      add(:source_type, :text)
      add(:source_id, :text)
      add(:promoted_by, :text)
    end

    drop(constraint(:decision_requests, :decision_kind))

    create(
      constraint(:decision_requests, :decision_kind,
        check:
          "kind IN ('ask_user_gate','approval','merge','policy','credential','scope','blocked_decision','other')"
      )
    )

    create(
      unique_index(:decision_requests, [:task_id, :question_key],
        where: "question_key IS NOT NULL AND status IN ('open','answered')",
        name: :decision_active_question
      )
    )

    create(index(:decision_requests, [:task_id, :question_key, :created_at]))
    create(index(:decision_requests, [:expires_at], where: "status='open'"))

    create(
      index(:task_events, [:task_id, :actor_id, :created_at, :id],
        where: "kind='update' AND body IS NOT NULL",
        name: :decision_owner_updates
      )
    )

    create(
      index(:messages, [:task_id, :sender_id, :created_at, :id],
        where: "task_id IS NOT NULL",
        name: :decision_owner_messages
      )
    )

    execute("UPDATE board_schema SET version=GREATEST(version,29) WHERE id=1")
  end

  def down, do: raise("Preserve captain questions and history; use a compatible image")
end
