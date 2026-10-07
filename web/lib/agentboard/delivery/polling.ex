defmodule Agentboard.Delivery.Polling do
  @moduledoc "Brief per-PR reservations. Provider I/O belongs after the reservation commits."
  alias Agentboard.Board.Operations
  alias Agentboard.Delivery.{PollState, PullRequest}
  alias Agentboard.Repo
  require Ash.Expr

  @lease_seconds 120
  @actor %{"agent" => "delivery-polling", "model" => "system", "harness" => "ash"}

  # Caller holds this canonical PR's lock in the inventory transaction.
  # Idempotent for the PR being persisted. A schema-7 writer can add inventory
  # without PollState; current-link catch-up does not cover cleared task URLs.
  def enroll(id, stamp, actor) do
    if is_nil(Ash.get!(PollState, id, not_found_error?: false)) do
      Operations.create(
        PollState,
        :enroll,
        %{id: id, registered_at: stamp, next_poll_at: stamp},
        actor
      )
    end
  end

  def reserve_due(limit \\ 20)

  def reserve_due(limit) when is_integer(limit) and limit in 1..100 do
    if enabled?() do
      Operations.transaction(fn ->
        %{rows: rows} =
          Repo.statement!(
            "SELECT id FROM delivery_poll_states WHERE enabled AND next_poll_at <= clock_timestamp() AND (lease_expires_at IS NULL OR lease_expires_at <= clock_timestamp()) ORDER BY next_poll_at,id LIMIT $1 FOR UPDATE SKIP LOCKED",
            [limit]
          )

        Enum.map(rows, fn [id] -> reserve(id) end)
      end)
    else
      {:ok, []}
    end
  end

  def reserve_due(_), do: {:error, "invalid_input", "Poll batch limit must be from 1 to 100"}

  def reserve_pr(id) when is_binary(id) do
    if enabled?() do
      Operations.transaction(fn ->
        %{rows: rows} =
          Repo.statement!(
            "SELECT id FROM delivery_poll_states WHERE id=$1 AND enabled AND next_poll_at<=clock_timestamp() AND (lease_expires_at IS NULL OR lease_expires_at<=clock_timestamp()) FOR UPDATE SKIP LOCKED",
            [id]
          )

        Enum.map(rows, fn [id] -> reserve(id) end)
      end)
    else
      {:ok, []}
    end
  end

  # A failed/incomplete fetch must not change provider evidence into success.
  # Delay is explicit so subsequent workers can honor provider Retry-After.
  def defer_poll(id, attempt_id, generation, delay_seconds, reason)
      when is_binary(id) and is_binary(attempt_id) and is_integer(generation) and
             generation > 0 and is_integer(delay_seconds) and delay_seconds in 1..604_800 and
             reason in ["unavailable", "rate_limited", "unauthorized", "incomplete"] do
    if enabled?() do
      Operations.transaction(fn ->
        Repo.statement!("SELECT id FROM delivery_poll_states WHERE id=$1 FOR UPDATE", [id])
        state = Operations.fetch!(PollState, id, "PR polling state not found")
        stamp = Operations.now()

        if state.generation != generation or state.attempt_id != attempt_id or
             is_nil(state.lease_expires_at) or
             DateTime.compare(state.lease_expires_at, stamp) != :gt do
          Operations.reject("conflict", "Poll reservation expired or replaced")
        end

        state
        |> Ash.Changeset.for_update(:defer, %{
          attempt_id: nil,
          lease_expires_at: nil,
          next_poll_at: DateTime.add(stamp, delay_seconds),
          last_error: reason
        })
        |> Ash.Changeset.filter(
          Ash.Expr.expr(
            generation == ^generation and attempt_id == ^attempt_id and
              lease_expires_at > fragment("clock_timestamp()")
          )
        )
        |> Ash.update!()
        |> Operations.public()
      end)
    else
      {:error, "disabled", "PR observation is disabled"}
    end
  end

  def defer_poll(_, _, _, _, _),
    do:
      {:error, "invalid_input",
       "A poll reservation, bounded delay and declared failure reason are required"}

  defp reserve(id) do
    state = Ash.get!(PollState, id)
    pr = Ash.get!(PullRequest, id)
    stamp = Operations.now()

    reserved =
      Operations.update(
        state,
        :reserve,
        %{
          generation: state.generation + 1,
          attempt_id: Ash.UUID.generate(),
          lease_expires_at: DateTime.add(stamp, @lease_seconds),
          last_attempt_at: stamp
        },
        @actor
      )

    %{
      id: id,
      attempt_id: reserved.attempt_id,
      generation: reserved.generation,
      lease_expires_at: reserved.lease_expires_at,
      url: pr.url,
      owner: pr.owner,
      repo: pr.repo,
      number: pr.number
    }
  end

  defp enabled?, do: Application.get_env(:agentboard, :pr_observation_enabled, false)
end

