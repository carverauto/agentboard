defmodule Agentboard.Context.Stamp do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    with {:ok, actor} <- Agentboard.Input.actor(actor),
         {:ok, %{harness: harness}} <- Ash.get(Agentboard.Board.Resources.Agent, actor["agent"]),
         true <- harness == actor["harness"] do
      changeset
      |> Ash.Changeset.force_change_attribute(:source_agent_id, actor["agent"])
      |> Ash.Changeset.force_change_attribute(:model, actor["model"])
      |> Ash.Changeset.force_change_attribute(:harness, actor["harness"])
    else
      _ ->
        Ash.Changeset.add_error(changeset,
          field: :source_agent_id,
          message: "Register a matching agent identity first"
        )
    end
  end
end

