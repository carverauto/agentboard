defmodule Agentboard.Delivery.ProviderAdmission do
  @moduledoc "Brief PostgreSQL budget allocation; provider requests happen after commit."
  alias Agentboard.Board.Operations
  alias Agentboard.Delivery.ProviderBudget
  alias Agentboard.Repo

  def acquire(provider) when provider in ["github", "buildbuddy"] do
    if Agentboard.Delivery.Scheduling.enabled?() do
      Operations.transaction(fn ->
        Repo.statement!("SELECT id FROM delivery_provider_budgets WHERE id=$1 FOR UPDATE", [
          provider
        ])

        budget = Operations.fetch!(ProviderBudget, provider, "Provider budget unavailable")
        stamp = Operations.now()
        expired? = DateTime.compare(budget.reset_at, stamp) != :gt
        # A PAT's 5,000/hour core limit is shared with other clients. Never
        # turn a historic/manual capacity bump into 300–500 requests/minute.
        capacity = if provider == "github", do: min(budget.capacity, 60), else: budget.capacity
        remaining = if expired?, do: capacity, else: min(budget.remaining, capacity)
        reset_at = if expired?, do: DateTime.add(stamp, 60), else: budget.reset_at

        blocked? = budget.blocked_until && DateTime.compare(budget.blocked_until, stamp) == :gt

        if blocked? do
          %{
            allowed: false,
            retry_after:
              min(604_800, max(1, DateTime.diff(budget.blocked_until, stamp, :second) + 1))
          }
        else
          if remaining > 0 do
            budget
            |> Ash.Changeset.for_update(:consume, %{remaining: remaining - 1, reset_at: reset_at})
            |> Ash.update!()

            %{allowed: true, retry_after: 0}
          else
            %{
              allowed: false,
              retry_after: max(1, div(DateTime.diff(reset_at, stamp, :millisecond) + 999, 1000))
            }
          end
        end
      end)
    else
      {:error, "disabled", "PR observation is disabled"}
    end
  end

  def acquire(_), do: {:error, "invalid_input", "Unknown provider"}

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
