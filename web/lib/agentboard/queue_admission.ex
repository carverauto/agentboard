defmodule Agentboard.QueueAdmission do
  @moduledoc "Per-seat queue admission prefix. Acquire before task locks, never beneath them."
  alias Agentboard.Repo

  def lock(nil), do: :ok

  def lock(id) when is_binary(id),
    do: Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key(id)])

  def lock(_),
    do: Agentboard.Board.Operations.reject("invalid_input", "Valid admission recipient required")

  def lock_action(action, actor, data) do
    target =
      cond do
        action in ~w(assign handoff) -> data["to"]
        action in ~w(claim reclaim) -> actor["agent"]
        true -> nil
      end

    lock(target)
  end

  def try_lock(id) do
    %{rows: [[locked]]} = Repo.statement!("SELECT pg_try_advisory_xact_lock($1)", [key(id)])
    locked
  end

  defp key(id) do
    <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "agentboard-queue-admission:" <> id)
    key
  end
end
