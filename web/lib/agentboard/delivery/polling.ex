defmodule Agentboard.Delivery.Polling do
  @moduledoc "Brief per-PR reservations. Provider I/O belongs after the reservation commits."
  alias Agentboard.Board.Operations
  alias Agentboard.Delivery.{Policy, Accountability, CISnapshot, PollState, PullRequest}
  alias Agentboard.Repo
  require Ash.Expr

  @lease_seconds 120
  @actor %{"agent" => "delivery-polling", "model" => "system", "harness" => "ash"}

  # One-time repair, explicitly invoked by the post-deploy operator runbook.
  # Dry run is the default; no provider I/O, CI projection or flag changes.
  def reconcile_disabled(ids, actor, apply? \\ false)

  def reconcile_disabled(ids, actor, apply?)
      when is_list(ids) and length(ids) in 1..100 and is_boolean(apply?) do
    with {:ok, actor} <- Agentboard.Input.actor(actor) do
      if not Enum.all?(ids, &is_binary/1) or length(Enum.uniq(ids)) != length(ids) do
        {:error, "invalid_input", "Distinct canonical PR IDs are required"}
      else
        Operations.transaction(fn ->
          # Immutable canonical PRs are protected by PollState's foreign key.
          # Only lock poll rows, in sorted order: an observer holding one may
          # need a canonical FK key-share lock to append its snapshot.
          %{rows: rows} =
            Repo.statement!(
              "SELECT id FROM delivery_poll_states WHERE id=ANY($1) ORDER BY id FOR UPDATE",
              [ids]
            )

          if length(rows) != length(ids),
            do: Operations.reject("not_found", "Repair cohort contains missing PR state")

          Enum.map(Enum.sort(ids), fn id ->
            state = Operations.fetch!(PollState, id, "PR polling state not found")
            reconcile_state(state, actor, apply?)
          end)
        end)
      end
    end
  end

  def reconcile_disabled(_, _, _),
    do:
      {:error, "invalid_input",
       "Repair requires 1–100 distinct IDs and an explicit apply boolean"}

  defp reconcile_state(state, actor, apply?) do
    %{rows: [[done?]]} =
      Repo.statement!(
        "SELECT EXISTS(SELECT 1 FROM delivery_poll_states_versions WHERE version_source_id=$1 AND version_action_name='reconcile_disabled')",
        [state.id]
      )

    stamp = Operations.now()

    cond do
      done? ->
        %{id: state.id, disposition: "already_reconciled"}

      state.lease_expires_at && DateTime.compare(state.lease_expires_at, stamp) == :gt ->
        Operations.reject("conflict", "Repair row has an active reservation")

      true ->
        terminal? = state.lifecycle in ["merged", "closed"]
        next_poll_at = if terminal?, do: DateTime.add(stamp, 3600), else: stamp

        if apply? do
          Operations.update(
            state,
            :reconcile_disabled,
            %{
              expected_generation: state.generation,
              expected_enabled: state.enabled,
              generation: state.generation + 1,
              enabled: not terminal?,
              next_poll_at: next_poll_at
            },
            actor
          )
        end

        %{
          id: state.id,
          disposition: if(terminal?, do: "retired", else: "reenabled"),
          lifecycle: state.lifecycle,
          apply: apply?
        }
    end
  end

  # Caller holds this canonical PR's lock in the inventory transaction.
  # Idempotent for the PR being persisted. A schema-7 writer can add inventory
  # without PollState; current-link catch-up does not cover cleared task URLs.
  def enroll(id, stamp, actor, linked? \\ false) do
    Repo.statement!("SELECT id FROM delivery_poll_states WHERE id=$1 FOR UPDATE", [id])
    state = Ash.get!(PollState, id, not_found_error?: false)

    cond do
      is_nil(state) ->
        Operations.create(
          PollState,
          :enroll,
          %{id: id, registered_at: stamp, next_poll_at: stamp},
          actor
        )

      not state.enabled and state.lifecycle == "closed" and
          (linked? or DateTime.compare(state.next_poll_at, stamp) != :gt) ->
        Operations.update(state, :resume, %{next_poll_at: stamp}, actor)

      state.enabled and linked? ->
        Operations.update(
          state,
          :request_poll,
          %{generation: state.generation + 1, next_poll_at: stamp},
          actor
        )

      true ->
        state
    end
  end

  def public_state(state),
    do: state |> Operations.public() |> Map.drop(["github_cache", "check_fingerprint"])

  def reserve_due(limit \\ 20)

  def reserve_due(limit) when is_integer(limit) and limit in 1..100 do
    if enabled?() do
      Operations.transaction(fn ->
        %{rows: rows} =
          Repo.statement!(
            "SELECT id FROM delivery_poll_states WHERE enabled AND next_poll_at <= clock_timestamp() AND (lease_expires_at IS NULL OR lease_expires_at <= clock_timestamp()) ORDER BY COALESCE(observed_at,registered_at),next_poll_at,id LIMIT $1 FOR UPDATE SKIP LOCKED",
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
             reason in [
               "unavailable",
               "rate_limited",
               "unauthorized",
               "incomplete",
               "base_changed",
               "budget_deferred",
               "fairness_deferred"
             ] do
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
          last_error: reason,
          budget_deferred_at:
            if(reason in ["budget_deferred", "fairness_deferred"],
              do: state.budget_deferred_at || stamp,
              else: state.budget_deferred_at
            )
        })
        |> Ash.Changeset.filter(
          Ash.Expr.expr(
            generation == ^generation and attempt_id == ^attempt_id and
              lease_expires_at > fragment("clock_timestamp()")
          )
        )
        |> Ash.update!()
        |> public_state()
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
        base_watch_sha = Agentboard.Delivery.BaseMonitor.assert_current!(reservation, result)

        Repo.statement!("SELECT id FROM delivery_poll_states WHERE id=$1 FOR UPDATE", [
          reservation.id
        ])

        state = Operations.fetch!(PollState, reservation.id, "PR polling state not found")
        stamp = Operations.now()

        assert_reservation!(state, reservation.attempt_id, reservation.generation, stamp)

        pr = Operations.fetch!(PullRequest, state.id, "PR not found")
        result = %{result | payload: Map.put(result.payload, "base_watch_sha", base_watch_sha)}
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

        fingerprint =
          :crypto.hash(:sha256, Jason.encode!(result.payload["attempts"] || []))
          |> Base.encode16(case: :lower)

        changed? =
          state.head_sha != result.head_sha or state.base_sha != result.base_sha or
            state.ci_state != result.ci_state or state.lifecycle != result.lifecycle or
            state.check_fingerprint != fingerprint

        stable = stable_poll?(result, changed?)
        unchanged = if stable, do: min(2, state.unchanged_polls + 1), else: 0
        terminal? = result.lifecycle in ["merged", "closed"]

        action =
          cond do
            terminal? -> :observe_terminal
            changed? -> :observe_change
            true -> :observe
          end

        projection =
          Operations.update(
            state,
            action,
            %{
              expected_generation: reservation.generation,
              expected_attempt_id: reservation.attempt_id,
              head_sha: result.head_sha,
              base_sha: result.base_sha,
              base_ref: result.payload["base_ref"],
              expected_base_sha: base_watch_sha,
              default_ref: result.payload["default_ref"] || state.default_ref,
              expected_default_sha:
                result.payload["default_tip_sha"] || state.expected_default_sha,
              ci_state: result.ci_state,
              lifecycle: result.lifecycle,
              observed_at: stamp,
              snapshot_id: snapshot.id,
              last_error: policy_error,
              attempt_id: nil,
              lease_expires_at: nil,
              next_poll_at: DateTime.add(stamp, cadence(result, unchanged)),
              unchanged_polls: unchanged,
              check_fingerprint: fingerprint,
              budget_deferred_at: nil
            },
            @actor
          )

        projection
        |> Ash.Changeset.for_update(
          :save_cache,
          %{github_cache: Map.get(result, :github_cache, %{})}
        )
        |> Ash.update!()

        Accountability.observe(snapshot, result, stamp)
        Agentboard.Delivery.Rebase.observe(snapshot, result, stamp)
        public_state(projection)
      end)
    else
      {:error, "disabled", "PR observation is disabled"}
    end
  end

  # Closed PRs get one metadata-only reopen check per hour; merged PRs stay
  # disabled. Stable non-pending evidence backs off from one to two to five minutes.
  defp cadence(%{lifecycle: lifecycle}, _) when lifecycle in ["merged", "closed"], do: 3600

  defp cadence(_result, 0), do: 60
  defp cadence(_result, 1), do: 120
  defp cadence(_result, _), do: 300

  defp stable_poll?(result, changed?) do
    pending? =
      Enum.any?(result.payload["attempts"] || [], fn attempt ->
        Map.get(attempt, :latest, attempt["latest"]) == true and
          Map.get(attempt, :status, attempt["status"]) != "completed"
      end)

    computing? =
      Map.has_key?(result.payload, "base_ref") and
        not is_nil(result.payload["base_ref"]) and is_nil(result.payload["mergeable"])

    conflict? =
      result.payload["mergeable"] == false and result.payload["mergeable_state"] == "dirty"

    not (changed? or result.ci_state == "pending" or pending? or computing? or conflict?)
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
      base_watches: Agentboard.Delivery.BaseMonitor.capture(pr),
      number: pr.number,
      github_cache: reserved.github_cache
    }
  end

  defp enabled?, do: Application.get_env(:agentboard, :pr_observation_enabled, false)
end
