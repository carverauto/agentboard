defmodule Agentboard.Delivery.ConflictConsumer do
  @moduledoc "Existing Event/Delivery and typed Message consumers share one fenced currentness map."
  alias Agentboard.Delivery.{ConflictCurrentness, ConflictSource}
  alias Agentboard.Cooperation.Event
  alias Agentboard.Wake.Intent
  require Ash.Query

  def lock(recipient, deliveries, wake) do
    descriptors =
      Enum.map(deliveries, &delivery_source/1) ++ Enum.map(List.wrap(wake), &wake_source/1)

    ConflictCurrentness.lock(Enum.reject(descriptors, &is_nil/1), recipient)
  end

  def admitted_deliveries(deliveries, context, suppress) do
    Enum.filter(deliveries, fn delivery ->
      result = delivery_state(delivery, context)

      if result.state in ~w(stale_order unsupported) and
           delivery.state not in ~w(handled suppressed),
         do: suppress.(delivery)

      result.state == "pending"
    end)
  end

  def project(delivery, context) do
    case delivery_state(delivery, context) do
      %{order_ref: reference, state: state} ->
        %{order_ref: reference, conflict_source_state: state}

      _ ->
        %{}
    end
  end

  def delivery_state(delivery, context) do
    state(delivery_source(delivery), context)
  end

  def wake_state(row, context) do
    result = state(wake_source(row), context)

    if row.source_ref["order_ref"] && result[:order_ref] != row.source_ref["order_ref"],
      do: %{state: "stale_order"},
      else: result
  end

  defp state(nil, _), do: %{state: "pending"}

  defp state({kind, id, version}, context),
    do: Map.get(context, {kind, to_string(id), version}, %{state: "unfenced"})

  defp delivery_source(delivery) do
    case Ash.get!(ConflictSource, delivery.event_id, not_found_error?: false) do
      nil ->
        row = Intent |> Ash.Query.filter(delivery_id == ^delivery.id) |> Ash.read_one!()
        wake_source(row)

      source ->
        event = Ash.get!(Event, source.id)
        {"event", source.id, event.source_key}
    end
  end

  defp wake_source(%{source_kind: "board_message", source_ref: %{"order_ref" => _}} = row),
    do: {"board_message", row.source_id, row.source_version}

  defp wake_source(_), do: nil
end
