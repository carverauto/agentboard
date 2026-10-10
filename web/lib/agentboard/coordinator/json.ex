defmodule Agentboard.Coordinator.JSON do
  @moduledoc "Reject ambiguous duplicate object keys on the new protocol only."

  def decode!(body), do: body |> Jason.decode!(objects: :ordered_objects) |> object()

  defp object(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    if length(keys) != length(Enum.uniq(keys)), do: raise(ArgumentError, "Duplicate JSON key")
    Map.new(values, fn {key, value} -> {key, object(value)} end)
  end

  defp object(values) when is_list(values), do: Enum.map(values, &object/1)
  defp object(value), do: value
end
