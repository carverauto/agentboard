defmodule Agentboard.Delivery.Polling do
  @moduledoc "Brief per-PR reservations. Provider I/O belongs after the reservation commits."
  alias Agentboard.Board.Operations
  alias Agentboard.Delivery.{Policy, Accountability, CISnapshot, PollState, PullRequest}
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

        assert_reservation!(state, attempt_id, generation, stamp)

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

  # Collection completed outside this transaction. Only the still-live
  # generation can append evidence and move this PR's current projection.
  def commit_observation(reservation, result) do
    if enabled?() do
      Operations.transaction(fn ->
        Repo.statement!("SELECT id FROM delivery_poll_states WHERE id=$1 FOR UPDATE", [
          reservation.id
        ])

        state = Operations.fetch!(PollState, reservation.id, "PR polling state not found")
        stamp = Operations.now()

        assert_reservation!(state, reservation.attempt_id, reservation.generation, stamp)

        pr = Operations.fetch!(PullRequest, state.id, "PR not found")
        result = Policy.classify(pr, result)

        policy_error =
          if result.ci_state == "passing" and result.payload["policy"] == "verified",
            do: nil,
            else: "policy_unknown"

        snapshot =
          Operations.create(
            CISnapshot,
            :record,
            %{
              id: Ash.UUID.generate(),
              pull_request_id: state.id,
              generation: state.generation,
              observed_at: stamp,
              head_sha: result.head_sha,
              base_sha: result.base_sha,
              lifecycle: result.lifecycle,
              ci_state: result.ci_state,
              payload: result.payload
            },
            @actor
          )

        changed? =
          state.head_sha != result.head_sha or state.base_sha != result.base_sha or
            state.ci_state != result.ci_state or state.lifecycle != result.lifecycle or
            state.last_error != policy_error

        action = if changed?, do: :observe_change, else: :observe

        projection =
          Operations.update(
            state,
            action,
            %{
              expected_generation: reservation.generation,
              expected_attempt_id: reservation.attempt_id,
              head_sha: result.head_sha,
              base_sha: result.base_sha,
              ci_state: result.ci_state,
              lifecycle: result.lifecycle,
              observed_at: stamp,
              snapshot_id: snapshot.id,
              last_error: policy_error,
              attempt_id: nil,
              lease_expires_at: nil,
              next_poll_at: DateTime.add(stamp, 60)
            },
            @actor
          )

        Accountability.observe(snapshot, result, stamp)
        Operations.public(projection)
      end)
    else
      {:error, "disabled", "PR observation is disabled"}
    end
  end

  defp assert_reservation!(state, attempt_id, generation, stamp) do
    if not state.enabled or state.generation != generation or state.attempt_id != attempt_id or
         is_nil(state.lease_expires_at) or DateTime.compare(state.lease_expires_at, stamp) != :gt do
      Operations.reject("conflict", "Poll reservation expired, disabled or replaced")
    end
  end

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
