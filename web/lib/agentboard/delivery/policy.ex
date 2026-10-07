defmodule Agentboard.Delivery.Policy do
  @moduledoc "Explicit repository expected-check policy. Complete head evidence may certify only configured head tests."
  # A merge-ref policy is deliberately unsupported until a collector proves that association.
  def classify(pr, result) do
    config = Application.get_env(:agentboard, :ci_policies, %{})[pr.owner <> "/" <> pr.repo]
    accepted = accepted_conclusions(config)
    attempts = result.payload["attempts"] || []
    latest = Enum.filter(attempts, &(field(&1, :latest) == true))

    qualified =
      is_map(config) and config["tested_ref"] == "head" and
        result.payload["coverage"] == "complete_head" and result.payload["tested_ref"] == "head" and
        is_list(config["required"]) and config["required"] != [] and
        Enum.all?(config["required"], &(is_binary(&1) and &1 != "")) and
        Enum.all?(config["required"], fn identity ->
          case Enum.filter(latest, &(field(&1, :identity) == identity)) do
            [check] ->
              field(check, :status) == "completed" and
                field(check, :conclusion) in accepted

            _ ->
              false
          end
        end) and
        Enum.all?(
          latest,
          &(field(&1, :status) == "completed" and
              field(&1, :conclusion) in accepted)
        )

    if qualified and result.ci_state != "failing" do
      %{
        result
        | ci_state: "passing",
          payload: Map.merge(result.payload, %{"policy" => "verified", "policy_config" => config})
      }
    else
      %{
        result
        | ci_state: if(result.ci_state == "passing", do: "unknown", else: result.ci_state),
          payload: Map.put(result.payload, "policy", "unknown")
      }
    end
  end

  defp accepted_conclusions(config) when is_map(config) do
    case Map.fetch(config, "accepted_conclusions") do
      :error -> ["success"]
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")), do: list, else: []
      _ -> []
    end
  end

  defp accepted_conclusions(_), do: ["success"]

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
