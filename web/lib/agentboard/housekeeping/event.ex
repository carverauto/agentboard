defmodule Agentboard.Housekeeping.Event do
  use Ash.Resource,
    domain: Agentboard.Housekeeping,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  postgres do
    table("housekeeping_events")
    repo(Agentboard.Repo)
  end

  event_log do
    record_id_type(:string)
    advisory_lock_key_generator(Agentboard.Housekeeping.EventLock)
  end

  actions do
    defaults([:read])
  end
end

defmodule Agentboard.Housekeeping.EventLock do
  use AshEvents.AdvisoryLockKeyGenerator

  def generate_key!(changeset, _default) do
    key = {changeset.resource, Ash.Changeset.get_attribute(changeset, :id)}
    <<lock::signed-64, _::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(key))
    lock
  end
end

