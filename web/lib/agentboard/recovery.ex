defmodule Agentboard.Recovery do
  @moduledoc """
  Disabled recovery checkpoint. There is no detector schedule, host restart
  delivery or escalation transport in this slice. Capturing an explicitly
  authorized dry-run candidate writes only an audited episode, never a task,
  decision, worker binding or native effect. Active capture is refused until
  the real policy store and authenticated host boundary ship.
  """
  alias Agentboard.Recovery.{Episode, Machine}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Repo
  require Ash.Query

  def readiness do
    %{
      mode: "disabled",
      restart_available: false,
      blocked_on: [
        "#154 policy store",
        "#155 escalation transport",
        "#156 authenticated host intents"
      ],
      seat_interface: "agentboard seat ensure|env|check"
    }
  end

  def preview(candidate, policy \\ %{}, now \\ DateTime.utc_now()),
    do: Machine.detect(candidate, policy, now)

  def capture(candidate, policy, actor) when is_map(actor) and is_map(policy) do
    cond do
      actor[:recovery_internal] != true ->
        {:error, "forbidden", "Internal recovery actor required"}

      policy["mode"] == "active" ->
        {:error, "unavailable", "Recovery integration dependencies are not ready"}

      true ->
        Ops.transaction(fn ->
          case Machine.detect(candidate, policy, Ops.now()) do
            {:ok, attrs} ->
              <<key::signed-64, _::binary>> =
                :crypto.hash(
                  :sha256,
                  :erlang.term_to_binary(
                    {attrs.agent_id, attrs.enrollment_revision, attrs.binding_epoch,
                     attrs.session_id, attrs.last_heartbeat_at}
                  )
                )

              Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])
              # Only recovery rows are touched here. Future active admission must
              # first re-read tasks -> decisions -> workers in that lock order.
              existing =
                Episode
                |> Ash.Query.filter(
                  agent_id == ^attrs.agent_id and
                    enrollment_revision == ^attrs.enrollment_revision and
                    binding_epoch == ^attrs.binding_epoch and session_id == ^attrs.session_id and
                    last_heartbeat_at == ^attrs.last_heartbeat_at
                )
                |> Ash.read_one!()

              row = existing || Ops.create(Episode, :record, attrs, actor)
              %{episode: Ops.public(row), dry_run: true, idempotent: not is_nil(existing)}

            {:error, reason} ->
              Ops.reject("conflict", "Recovery candidate refused: #{reason}")
          end
        end)
    end
  end

  def capture(_, _, _), do: {:error, "invalid_input", "Invalid recovery checkpoint"}
end

