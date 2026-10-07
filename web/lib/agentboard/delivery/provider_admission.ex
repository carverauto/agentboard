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
        remaining = if expired?, do: budget.capacity, else: budget.remaining
        reset_at = if expired?, do: DateTime.add(stamp, 60), else: budget.reset_at

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
      end)
    else
      {:error, "disabled", "PR observation is disabled"}
    end
  end

  def acquire(_), do: {:error, "invalid_input", "Unknown provider"}
end
