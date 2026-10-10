defmodule Agentboard.Coordinator.Contract do
  @moduledoc "Strict revision-1 request validation and deterministic bounded wire pages."
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @hash ~r/\A[0-9a-f]{64}\z/
  @dispositions ~w(reviewed escalated deferred)

  def uuid?(id), do: is_binary(id) and Regex.match?(@uuid, id)
  def hash?(value), do: is_binary(value) and Regex.match?(@hash, value)

  def text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, <<0>>)

  def ack(data) do
    if exact?(data, ~w(retry_key items)) and text?(data["retry_key"], 128) and
         is_list(data["items"]) and length(data["items"]) in 1..20 and
         Enum.all?(data["items"], &item?/1) and
         length(Enum.uniq_by(data["items"], & &1["id"])) == length(data["items"]) do
      items = Enum.sort_by(data["items"], & &1["id"])
      normalized = Enum.map(items, fn item -> Enum.map(~w(id version disposition), &item[&1]) end)
      {:ok, %{key: data["retry_key"], items: items, hash: digest([1, "ack", normalized])}}
    else
      invalid("Exact retry_key and 1–20 unique versioned handling items required")
    end
  end

  def heartbeat(data) do
    if is_map(data) and Enum.all?(Map.keys(data), &(&1 in ~w(status task))) and
         data["status"] in ~w(idle busy) and
         (not Map.has_key?(data, "task") or Agentboard.Input.slug?(data["task"])) do
      :ok
    else
      invalid("Heartbeat accepts only status and an optional own task")
    end
  end

  def query(data, coordinator) do
    with true <- is_map(data) and Enum.all?(Map.keys(data), &(&1 in ~w(limit max_bytes cursor))),
         {:ok, limit} <- number(data["limit"], 20, 1..100),
         {:ok, bytes} <- number(data["max_bytes"], 16_384, 4_096..65_536),
         {:ok, cursor} <- cursor(data["cursor"], coordinator, limit, bytes) do
      {:ok, %{limit: limit, max_bytes: bytes, cursor: cursor}}
    else
      _ -> invalid("Invalid coordinator page options or cursor")
    end
  end

  def page(rows, coordinator, options) do
    # At most limit+1 rows enter. Include the final cursor/envelope in each
    # candidate measurement; selecting metadata first is not a byte bound.
    count = min(length(rows), options.limit)

    candidate =
      if count == 0 do
        envelope([], coordinator, options, false)
      else
        Enum.reduce_while(count..1//-1, nil, fn n, _ ->
          packet = envelope(Enum.take(rows, n), coordinator, options, length(rows) > n)

          if byte_size(Jason.encode!(packet)) <= options.max_bytes,
            do: {:halt, packet},
            else: {:cont, nil}
        end)
      end

    if candidate && byte_size(Jason.encode!(candidate)) <= options.max_bytes,
      do: {:ok, candidate},
      else: invalid("A coordinator item cannot fit within max_bytes; increase the byte budget")
  end

  def digest(value),
    do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  defp item?(item),
    do:
      exact?(item, ~w(id version disposition)) and uuid?(item["id"]) and
        hash?(item["version"]) and item["disposition"] in @dispositions

  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp number(nil, default, _), do: {:ok, default}

  defp number(value, _, range) when is_binary(value) and byte_size(value) <= 6 do
    case Integer.parse(value) do
      {n, ""} -> if n in range and Integer.to_string(n) == value, do: {:ok, n}, else: :error
      _ -> :error
    end
  end

  defp number(_, _, _), do: :error

  defp cursor(nil, _, _, _), do: {:ok, nil}

  defp cursor(value, coordinator, limit, bytes)
       when is_binary(value) and byte_size(value) <= 4096 do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, [1, ^coordinator, ^limit, ^bytes, created, id]} <- Jason.decode(decoded),
         true <- uuid?(id),
         true <- is_binary(created) and byte_size(created) in 20..32,
         true <-
           Regex.match?(
             ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|\+00:00)\z/,
             created
           ),
         {:ok, %{year: year}, 0} when year in 1..9999 <- DateTime.from_iso8601(created),
         true <- Base.url_encode64(decoded, padding: false) == value do
      {:ok, [created, id]}
    else
      _ -> :error
    end
  end

  defp cursor(_, _, _, _), do: :error

  defp envelope(items, coordinator, options, more) do
    next =
      if more do
        last = List.last(items)

        [1, coordinator, options.limit, options.max_bytes, last["created_at"], last["id"]]
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)
      end

    %{
      protocol_revision: 1,
      coordinator_id: coordinator,
      items: items,
      complete: not more,
      next_cursor: next,
      limits: Map.take(options, [:limit, :max_bytes]),
      restart_from_start: true,
      policy_evaluation: "not_available"
    }
  end

  defp invalid(message), do: {:error, "invalid_input", message}
end
