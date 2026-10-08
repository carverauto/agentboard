defmodule Agentboard.Board.Reads do
  @moduledoc "Ash reads with the existing API v1 ordering, filter-bound cursors and watch snapshots."
  alias Agentboard.Board.Resources.{Agent, Task, TaskEvent, Message}
  alias Agentboard.Board.Operations
  require Ash.Query

  def show("tasks", id, filters) do
    with true <- Agentboard.Input.slug?(id),
         {:ok, query} <- load_flags(Task |> Ash.Query.filter(id == ^id), "tasks", filters),
         {:ok, task} <- fetch(query),
         {:ok, events} <- page("events", Map.put(filters, "task", id)),
         {:ok, documents} <- Agentboard.Documents.list(id),
         {:ok, archive} <- archive(id) do
      [task] = decorate([task], "tasks")

      {:ok,
       %{
         "task" => task,
         "events" => events["events"],
         "next_cursor" => events["next_cursor"],
         "documents" => documents["documents"],
         "archive" => archive
       }}
    else
      false -> invalid("Invalid task ID")
      error -> error
    end
  end

  def show("agents", id, filters) do
    with true <- Agentboard.Input.slug?(id),
         {:ok, query} <- load_flags(Agent |> Ash.Query.filter(id == ^id), "agents", filters),
         {:ok, _} <- Agentboard.Availability.expire_due(),
         {:ok, agent} <- fetch(query) do
      history = Agentboard.Availability.history(agent)
      [agent] = decorate([agent], "agents")
      {:ok, Map.merge(%{"agent" => agent}, history)}
    else
      false -> invalid("Invalid agent ID")
      error -> error
    end
  end

  def count(resource, filters) do
    with {:ok, {module, _order, fields}} <- spec(resource),
         :ok <- validate(filters, fields, resource),
         {:ok, query} <- filtered(module, filters, fields, resource),
         {:ok, total} <- Ash.count(Agentboard.Repo.read_query(query), domain: Agentboard.Board) do
      {:ok, total}
    else
      {:error, code, message} -> {:error, code, message}
      _ -> {:error, "unavailable", "Board database is unavailable"}
    end
  rescue
    DBConnection.ConnectionError -> {:error, "unavailable", "Board database is unavailable"}
    Postgrex.Error -> {:error, "unavailable", "Board database is unavailable"}
  end

  def page(resource, filters), do: read(resource, filters, false)
  def snapshot(resource, filters), do: read(resource, Map.drop(filters, ~w(limit cursor)), true)

  defp read(resource, filters, snapshot?) do
    with {:ok, {module, order, fields}} <- spec(resource),
         :ok <- validate(filters, fields, resource),
         {:ok, limit} <- limit(filters),
         {:ok, query} <- filtered(module, filters, fields, resource),
         {:ok, query} <- cursor(query, resource, filters),
         query = Ash.Query.sort(query, order),
         query = if(snapshot?, do: query, else: Ash.Query.limit(query, limit + 1)),
         {:ok, query} <- load_flags(query, resource, filters),
         {:ok, _} <-
           if(resource == "agents", do: Agentboard.Availability.expire_due(), else: {:ok, %{}}),
         {:ok, records} <- ash_read(query) do
      rows = decorate(records, resource)
      rows = if snapshot?, do: rows, else: Enum.take(rows, limit)

      next =
        if not snapshot? and length(records) > limit,
          do: encode(resource, filters, List.last(rows)),
          else: nil

      {:ok, %{resource => rows, "next_cursor" => next}}
    else
      {:error, code, message} -> {:error, code, message}
      _ -> {:error, "unavailable", "Board database is unavailable"}
    end
  rescue
    DBConnection.ConnectionError -> {:error, "unavailable", "Board database is unavailable"}
  end

  defp spec("tasks"),
    do:
      {:ok,
       {Task, [priority: :asc, updated_at: :desc, id: :asc],
        %{
          "status" => :status,
          "owner" => :assignee_id,
          "repo" => :repo,
          "label" => :labels,
          "archive" => :archive
        }}}

  defp spec("agents"),
    do:
      {:ok,
       {Agent, [id: :asc],
        %{
          "harness" => :harness,
          "status" => :reported_status,
          "availability" => :availability_state
        }}}

  defp spec("messages"),
    do:
      {:ok, {Message, [created_at: :asc, id: :asc], %{"to" => :recipient_id, "task" => :task_id}}}

  defp spec("events"), do: {:ok, {TaskEvent, [created_at: :asc, id: :asc], %{"task" => :task_id}}}

  defp validate(filters, fields, resource) do
    allowed =
      Map.keys(fields) ++
        ~w(limit cursor stale_after) ++ if(resource == "messages", do: ["unread"], else: [])

    cond do
      not Enum.all?(filters, fn {k, v} ->
        is_binary(k) and is_binary(v) and byte_size(v) <= 4096
      end) ->
        invalid("List filters must be scalar strings")

      Enum.any?(Map.keys(filters), &(&1 not in allowed)) ->
        invalid("Unknown list filter")

      Map.has_key?(filters, "archive") and filters["archive"] not in ~w(active archived) ->
        invalid("Unknown archive filter")

      Map.has_key?(filters, "unread") and filters["unread"] not in ~w(true false) ->
        invalid("Unknown unread filter")

      resource == "agents" and Map.has_key?(filters, "availability") and
          filters["availability"] not in ~w(active reserved out_of_service) ->
        invalid("Unknown availability filter")

      resource == "agents" ->
        case threshold(filters) do
          {:ok, _} -> :ok
          error -> error
        end

      true ->
        :ok
    end
  end

  defp filtered(module, filters, fields, resource) do
    query =
      Enum.reduce(Map.take(filters, Map.keys(fields)), Ash.Query.new(module), fn
        {"label", label}, query ->
          Ash.Query.filter(query, ^label in labels)

        {"archive", "archived"}, query ->
          Ash.Query.filter(query, exists(archive, not is_nil(archived_at)))

        {"archive", "active"}, query ->
          Ash.Query.filter(query, not exists(archive, not is_nil(archived_at)))

        {key, value}, query ->
          Ash.Query.filter_input(query, %{fields[key] => value})
      end)

    query =
      if resource == "messages" and filters["unread"] == "true",
        do: Ash.Query.filter(query, is_nil(read_at) and not is_nil(recipient_id)),
        else: query

    {:ok, query}
  end

  defp cursor(query, resource, filters) do
    case filters["cursor"] do
      nil ->
        {:ok, query}

      encoded ->
        with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
             {:ok, %{"resource" => ^resource, "filters" => digest, "values" => values}} <-
               Jason.decode(raw),
             true <- digest == digest(filters) do
          after_cursor(query, resource, values)
        else
          _ -> invalid("Cursor does not match this query")
        end
    end
  end

  defp after_cursor(query, "tasks", [p, stamp, id])
       when is_integer(p) and p >= 0 and is_binary(stamp) do
    with true <- Agentboard.Input.slug?(id), {:ok, time, _} <- DateTime.from_iso8601(stamp) do
      {:ok,
       Ash.Query.filter(
         query,
         priority > ^p or
           (priority == ^p and (updated_at < ^time or (updated_at == ^time and id > ^id)))
       )}
    else
      _ -> invalid("Cursor does not match this query")
    end
  end

  defp after_cursor(query, "agents", [id]) do
    if Agentboard.Input.slug?(id),
      do: {:ok, Ash.Query.filter(query, id > ^id)},
      else: invalid("Cursor does not match this query")
  end

  defp after_cursor(query, resource, [stamp, id])
       when resource in ~w(events messages) and is_integer(id) and id > 0 and is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, time, _} ->
        {:ok, Ash.Query.filter(query, created_at > ^time or (created_at == ^time and id > ^id))}

      _ ->
        invalid("Cursor does not match this query")
    end
  end

  defp after_cursor(_, _, _), do: invalid("Cursor does not match this query")

  defp load_flags(query, "tasks", _filters),
    do: {:ok, Ash.Query.load(query, [:claim_expired, :archive_revision])}

  defp load_flags(query, "agents", filters) do
    case threshold(filters) do
      {:ok, seconds} ->
        {:ok,
         Ash.Query.load(query, [:availability, :availability_state, stale: %{seconds: seconds}])}

      error ->
        error
    end
  end

  defp load_flags(query, _, _), do: {:ok, query}

  defp decorate(records, "tasks") do
    Enum.map(records, fn row ->
      row
      |> Operations.public()
      |> Map.merge(%{
        "archive_revision" => row.archive_revision,
        "claim_expired" => row.claim_expired
      })
    end)
  end

  defp decorate(records, "agents") do
    Enum.map(records, fn row ->
      row
      |> Operations.public()
      |> Map.put("stale", row.stale)
      |> Map.put("availability", row.availability)
      |> Map.put("routing_eligible", row.availability_state == "active")
    end)
  end

  defp decorate(records, _), do: Enum.map(records, &Operations.public/1)

  defp archive(id) do
    query = Agentboard.Housekeeping.Archive |> Ash.Query.filter(id == ^id)

    case ash_read_one(query) do
      {:ok, nil} -> {:ok, %{"id" => id, "revision" => 0, "archived_at" => nil}}
      {:ok, row} -> {:ok, Operations.public(row)}
      error -> error
    end
  end

  defp fetch(query) do
    case ash_read_one(query) do
      {:ok, nil} -> {:error, "not_found", "Record not found"}
      {:ok, row} -> {:ok, row}
      error -> error
    end
  end

  defp ash_read(query) do
    case Ash.read(Agentboard.Repo.read_query(query)) do
      {:ok, rows} -> {:ok, rows}
      _ -> unavailable()
    end
  rescue
    DBConnection.ConnectionError -> unavailable()
    Postgrex.Error -> unavailable()
  end

  defp ash_read_one(query) do
    case Ash.read_one(Agentboard.Repo.read_query(query)) do
      {:ok, row} -> {:ok, row}
      _ -> unavailable()
    end
  rescue
    DBConnection.ConnectionError -> unavailable()
    Postgrex.Error -> unavailable()
  end

  defp unavailable, do: {:error, "unavailable", "Board database is unavailable"}

  defp encode(resource, filters, record) do
    fields =
      case resource do
        "tasks" -> ~w(priority updated_at id)
        "agents" -> ~w(id)
        _ -> ~w(created_at id)
      end

    Jason.encode!(%{
      resource: resource,
      filters: digest(filters),
      values: Enum.map(fields, &record[&1])
    })
    |> Base.url_encode64(padding: false)
  end

  defp digest(filters),
    do:
      :crypto.hash(
        :sha256,
        Jason.encode!(
          filters
          |> Map.drop(~w(cursor limit))
          |> Enum.sort()
          |> Enum.map(fn {k, v} -> [k, v] end)
        )
      )
      |> Base.encode16(case: :lower)

  defp limit(filters) do
    case Integer.parse(Map.get(filters, "limit", "100")) do
      {n, ""} when n in 1..1000 -> {:ok, n}
      _ -> invalid("Page limit must be 1–1000")
    end
  end

  defp threshold(filters) do
    case Float.parse(Map.get(filters, "stale_after", "600")) do
      {n, ""} ->
        if Agentboard.Input.representable_offset?(n),
          do: {:ok, n},
          else: invalid("Stale threshold must be positive seconds")

      _ ->
        invalid("Stale threshold must be positive seconds")
    end
  end

  defp invalid(message), do: {:error, "invalid_input", message}
end
