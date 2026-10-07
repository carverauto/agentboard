defmodule Agentboard.Delivery.Policy do
  @moduledoc "Explicit repository expected-check policy. Complete head evidence may certify only configured head tests."
  # A merge-ref policy is deliberately unsupported until a collector proves that association.
  def classify(pr, result) do
    config = Application.get_env(:agentboard, :ci_policies, %{})[pr.owner <> "/" <> pr.repo]
    attempts = result.payload["attempts"] || []
    latest = Enum.filter(attempts, &(field(&1, :latest) == true))

    qualified =
      is_map(config) and config["tested_ref"] == "head" and
        result.payload["coverage"] == "complete_head" and result.payload["tested_ref"] == "head" and
        is_list(config["required"]) and config["required"] != [] and
        Enum.all?(config["required"], fn identity ->
          case Enum.filter(latest, &(field(&1, :identity) == identity)) do
            [check] ->
              field(check, :status) == "completed" and
                field(check, :conclusion) in (config["accepted_conclusions"] || ["success"])

            _ ->
              false
          end
        end) and
        Enum.all?(
          latest,
          &(field(&1, :conclusion) in (config["accepted_conclusions"] || ["success"]))
        )

    if qualified and result.ci_state != "failing" do
      %{
        result
        | ci_state: "passing",
          payload: Map.merge(result.payload, %{"policy" => "verified", "policy_config" => config})
      }
    else
      result
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
