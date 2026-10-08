defmodule Agentboard.Delivery.WorkerAction do
  @moduledoc "Shared Oban return mapping for the delivery domain's single-item Ash actions."
  def run(resource, action, args) do
    resource
    |> Ash.ActionInput.for_action(action, args,
      actor: %{role: :system, id: "delivery-observation"}
    )
    |> Ash.run_action()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, error} -> AshOban.check_for_oban_return(error) || {:error, error}
    end
  end
end
