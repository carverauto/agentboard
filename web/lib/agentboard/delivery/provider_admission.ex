defmodule Agentboard.Delivery.ProviderAdmission do
  @moduledoc "Brief PostgreSQL budget allocation; provider requests happen after commit."
  alias Agentboard.Board.Operations
  alias Agentboard.Delivery.{ProviderBudget, PollCredit}
  alias Agentboard.Repo

  def acquire(provider) when provider in ["github", "buildbuddy"] do
    if Agentboard.Delivery.Scheduling.enabled?() do
      Operations.transaction(fn -> allocate(provider, 1) end)
    else
      {:error, "disabled", "PR observation is disabled"}
    end
  end

  def acquire(_), do: {:error, "invalid_input", "Unknown provider"}

  # Always reserve the collector's hard maximum, not a guess from yesterday's
  # suite count. More suites/pages can never overrun an admitted poll locally.
  def reserve_poll(pr, cost) when cost in 1..32 do
    if Agentboard.Delivery.Scheduling.enabled?() do
      Operations.transaction(fn ->
        lock("github")
        reap()

        %{rows: rows} =
          Repo.statement!(
            """
            SELECT s.id FROM delivery_poll_states s
            WHERE s.enabled AND s.next_poll_at<=clock_timestamp()
              AND NOT EXISTS (SELECT 1 FROM delivery_poll_credits c
                WHERE c.pull_request_id=s.id AND c.expires_at>clock_timestamp())
            ORDER BY COALESCE(s.observed_at,s.registered_at),s.next_poll_at,s.id LIMIT 1
            """,
            []
          )

        cond do
          rows != [[pr.id]] ->
            %{allowed: false, retry_after: 1, reason: "fairness_deferred"}

          true ->
            case allocate("github", cost) do
              %{allowed: true, reset_at: reset_at} ->
                Ash.create!(
                  Ash.Changeset.for_create(PollCredit, :reserve, %{
                    id: pr.attempt_id,
                    pull_request_id: pr.id,
                    remaining: cost,
                    window_end: reset_at,
                    expires_at: pr.lease_expires_at
                  })
                )

                %{allowed: true, credit: pr.attempt_id}

              refused ->
                Map.put(refused, :reason, "budget_deferred")
            end
        end
      end)
    else
      {:error, "disabled", "PR observation is disabled"}
    end
  end

  def spend(credit) do
    Operations.transaction(fn ->
      lock("github")
      budget = current_budget("github")
      row = credit!(credit)
      stamp = Operations.now()

      cond do
        budget.blocked_until && DateTime.compare(budget.blocked_until, stamp) == :gt ->
          %{allowed: false, retry_after: max(1, DateTime.diff(budget.blocked_until, stamp) + 1)}

        row.remaining > 0 ->
          row
          |> Ash.Changeset.for_update(:spend, %{remaining: row.remaining - 1})
          |> Ash.update!()

          %{allowed: true, window_end: row.window_end}

        true ->
          Operations.reject("incomplete", "Poll request bound exceeded")
      end
    end)
  end

  # Authorized 304s are free under GitHub's primary rate limit. Restore only
  # this still-live reservation's credit, never somebody else's bucket.
  def not_modified(credit, charged_window) do
    Operations.transaction(fn ->
      lock("github")
      current_budget("github")
      row = credit!(credit)
      # A response arriving after rollover cannot refund a debit from the old
      # window into a new one. That would erase somebody else's new request.
      if row.window_end == charged_window do
        row
        |> Ash.Changeset.for_update(:spend, %{remaining: min(32, row.remaining + 1)})
        |> Ash.update!()
      end

      :ok
    end)
  end

  def release(credit) do
    Operations.transaction(fn ->
      lock("github")
      row = Ash.get!(PollCredit, credit, not_found_error?: false)
      if row, do: refund(row)
      :ok
    end)
  end

  defp credit!(id) do
    row = Operations.fetch!(PollCredit, id, "Poll credit no longer active", "incomplete")

    if DateTime.compare(row.expires_at, Operations.now()) != :gt,
      do: Operations.reject("incomplete", "Poll credit expired")

    row
  end

  defp reap do
    %{rows: rows} =
      Repo.statement!(
        "SELECT id FROM delivery_poll_credits WHERE expires_at<=clock_timestamp() ORDER BY id",
        []
      )

    Enum.each(rows, fn [id] -> refund(Ash.get!(PollCredit, id)) end)
  end

  defp refund(row) do
    budget = Operations.fetch!(ProviderBudget, "github", "Provider budget unavailable")

    if budget.reset_at == row.window_end do
      budget
      |> Ash.Changeset.for_update(
        :consume,
        %{remaining: min(min(budget.capacity, 60), budget.remaining + row.remaining)}
      )
      |> Ash.update!()
    end

    Ash.destroy!(row)
  end

  defp lock(provider),
    do:
      Repo.statement!("SELECT id FROM delivery_provider_budgets WHERE id=$1 FOR UPDATE", [
        provider
      ])

  defp allocate(provider, cost) do
    lock(provider)
    budget = current_budget(provider)
    stamp = Operations.now()
    capacity = if provider == "github", do: min(budget.capacity, 60), else: budget.capacity
    remaining = min(budget.remaining, capacity)
    reset_at = budget.reset_at
    blocked? = budget.blocked_until && DateTime.compare(budget.blocked_until, stamp) == :gt

    cond do
      blocked? ->
        %{
          allowed: false,
          retry_after: min(604_800, max(1, DateTime.diff(budget.blocked_until, stamp) + 1))
        }

      remaining >= cost ->
        budget
        |> Ash.Changeset.for_update(
          :consume,
          %{remaining: remaining - cost, reset_at: reset_at}
        )
        |> Ash.update!()

        %{allowed: true, retry_after: 0, reset_at: reset_at}

      true ->
        %{
          allowed: false,
          retry_after: max(1, div(DateTime.diff(reset_at, stamp, :millisecond) + 999, 1000))
        }
    end
  end

  # Caller holds the shared provider row. Carry still-live unused credit into
  # the new minute before admitting any poll/workflow request, so a slow poll
  # cannot spend its old reservation on top of a fresh sixty-request bucket.
  defp current_budget(provider) do
    budget = Operations.fetch!(ProviderBudget, provider, "Provider budget unavailable")
    stamp = Operations.now()

    if DateTime.compare(budget.reset_at, stamp) != :gt do
      capacity = if provider == "github", do: min(budget.capacity, 60), else: budget.capacity
      reset_at = DateTime.add(stamp, 60)

      carried =
        if provider == "github" do
          reap()

          %{rows: [[remaining]]} =
            Repo.statement!(
              "SELECT COALESCE(sum(remaining),0)::bigint FROM delivery_poll_credits",
              []
            )

          Repo.statement!("UPDATE delivery_poll_credits SET window_end=$1", [reset_at])
          remaining
        else
          0
        end

      budget
      |> Ash.Changeset.for_update(
        :consume,
        %{remaining: max(0, capacity - carried), reset_at: reset_at}
      )
      |> Ash.update!()
    else
      budget
    end
  end

  # Serialize only this provider's deadline; a later response cannot shorten it.
  def block(provider, seconds)
      when provider in ["github", "buildbuddy"] and
             is_integer(seconds) and seconds > 0 and seconds <= 2_147_483_647 do
    Operations.transaction(fn ->
      Repo.statement!("SELECT id FROM delivery_provider_budgets WHERE id=$1 FOR UPDATE", [
        provider
      ])

      budget = Operations.fetch!(ProviderBudget, provider, "Provider budget unavailable")
      deadline = DateTime.add(Operations.now(), seconds)

      deadline =
        if budget.blocked_until && DateTime.compare(budget.blocked_until, deadline) == :gt,
          do: budget.blocked_until,
          else: deadline

      budget |> Ash.Changeset.for_update(:consume, %{blocked_until: deadline}) |> Ash.update!()
      :ok
    end)
  end
end
