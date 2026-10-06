defmodule Agentboard.Board.AuditEvent do
  @moduledoc "Append-only Ash action audit. Historical task_events remain the public timeline."
  use Ash.Resource,
    domain: Agentboard.Board,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  postgres do
    table("board_action_events")
    repo(Agentboard.Repo)
  end

  event_log do
    record_id_type(Agentboard.Board.AuditID)
    advisory_lock_key_generator(Agentboard.Board.AuditLock)
  end

  actions do
    defaults([:read])
  end
end

defmodule Agentboard.Board.AuditLock do
  use AshEvents.AdvisoryLockKeyGenerator

  def generate_key!(changeset, _default) do
    key = {changeset.resource, Ash.Changeset.get_attribute(changeset, :id)}
    <<lock::signed-64, _::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(key))
    lock
  end
end

