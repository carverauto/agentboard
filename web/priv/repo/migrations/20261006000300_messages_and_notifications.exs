defmodule Agentboard.Repo.Migrations.MessagesAndNotifications do
  use Ecto.Migration

  def up do
    create table(:messages) do
      add(:sender_id, references(:agents, type: :text, on_delete: :restrict), null: false)
      add(:model, :text, null: false)
      add(:harness, :text, null: false)
      add(:recipient_id, references(:agents, type: :text, on_delete: :restrict))
      add(:task_id, references(:tasks, type: :text, on_delete: :restrict))
      add(:body, :text, null: false)
      add(:created_at, :timestamptz, null: false, default: fragment("clock_timestamp()"))
      add(:read_at, :timestamptz)
      add(:read_model, :text)
      add(:read_harness, :text)
    end

    create(
      constraint(:messages, :message_destination,
        check: "recipient_id IS NOT NULL OR task_id IS NOT NULL"
      )
    )

    create(
      constraint(:messages, :message_content,
        check: "length(btrim(body))>0 AND length(btrim(model))>0 AND length(btrim(harness))>0"
      )
    )

    create(
      constraint(:messages, :message_read_context,
        check:
          "(read_at IS NULL AND read_model IS NULL AND read_harness IS NULL) OR (recipient_id IS NOT NULL AND read_at IS NOT NULL AND read_model IS NOT NULL AND read_harness IS NOT NULL AND length(btrim(read_model))>0 AND length(btrim(read_harness))>0)"
      )
    )

    create(index(:messages, [:recipient_id, :read_at, :created_at, :id]))
    create(index(:messages, [:task_id, :created_at, :id]))

    Application.app_dir(:agentboard, "priv/sql/messages.sql")
    |> File.read!()
    |> String.split("\n-- statement-break\n")
    |> Enum.each(&execute/1)

    Application.app_dir(:agentboard, "priv/sql/notifications.sql")
    |> File.read!()
    |> String.split("\n-- statement-break\n")
    |> Enum.each(&execute/1)

    execute("UPDATE board_schema SET version=2 WHERE id=1")
  end

  def down, do: raise("Preserve messages/history; roll back a compatible application image")
end

