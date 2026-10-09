defmodule Agentboard.CoordinatorTriage.Metadata do
  @moduledoc "Exact versioned note intent. Text is never classification evidence."
  @maximum 9_007_199_254_740_991
  @categories ~w(status ci conflict next_work needs_judgment)

  def valid?(value) when is_map(value) do
    exact?(value, ~w(version category attention source)) and value["version"] === 1 and
      value["category"] in @categories and value["attention"] in ~w(routine captain) and
      source?(value["category"], value["source"]) and byte_size(Jason.encode!(value)) <= 4096
  end

  def valid?(_), do: false
  def classification(nil), do: "unclassified"
  def classification(%{"attention" => "captain"}), do: "captain_addressed"
  def classification(%{"category" => category}), do: category

  defp source?(category, nil), do: category in ~w(status next_work needs_judgment)

  defp source?("status", %{"kind" => "task_status"} = source),
    do:
      exact?(source, ~w(kind task_id task_event_id task_revision)) and
        task?(source["task_id"]) and positive?(source["task_event_id"]) and
        positive?(source["task_revision"])

  defp source?(category, %{"kind" => "cooperation_event"} = source)
       when category in ~w(ci conflict),
       do:
         exact?(source, ~w(kind event_id source_key)) and uuid?(source["event_id"]) and
           is_binary(source["source_key"]) and
           length(String.codepoints(source["source_key"])) in 1..240 and
           not Regex.match?(~r/[\x00-\x1f\x7f]/u, source["source_key"])

  defp source?("next_work", %{"kind" => "task_assignment"} = source),
    do:
      exact?(source, ~w(kind task_id assignment_revision)) and task?(source["task_id"]) and
        positive?(source["assignment_revision"])

  defp source?("needs_judgment", %{"kind" => "decision_request"} = source),
    do: exact?(source, ~w(kind request_id)) and uuid?(source["request_id"])

  defp source?(_, _), do: false
  defp exact?(value, fields), do: Enum.sort(Map.keys(value)) == Enum.sort(fields)
  defp positive?(value), do: is_integer(value) and value in 1..@maximum

  defp task?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/, value)

  defp uuid?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)
end
