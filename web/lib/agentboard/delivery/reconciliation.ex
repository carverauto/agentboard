defmodule Agentboard.Delivery.Reconciliation do
  @moduledoc "Bounded keyset pages with per-record transactions and durable continuation."
  alias Agentboard.{Repo, Board.Operations}
  require Ash.Query

  def page(query, cursor, continue, visit) do
    query = query |> Ash.Query.sort(id: :asc) |> Ash.Query.limit(101)
    query = if cursor, do: Ash.Query.filter(query, id > ^cursor), else: query

    with {:ok, rows} <- query |> Repo.read_query() |> Ash.read(),
         {:ok, counts} <- visit_page(Enum.take(rows, 100), visit) do
      next = if length(rows) > 100, do: Enum.at(rows, 99).id
      if next, do: continue.(next)
      {:ok, Map.put(counts, :next_cursor, next)}
    else
      {:error, _code, message} -> {:error, message}
      {:error, error} -> {:error, error}
    end
  end

  defp visit_page(rows, visit) do
    Enum.reduce_while(rows, {:ok, %{scanned: 0, completed: 0}}, fn row, {:ok, counts} ->
      case Operations.transaction(fn -> visit.(row.id) end) do
        {:ok, changed?} ->
          {:cont,
           {:ok,
            %{
              scanned: counts.scanned + 1,
              completed: counts.completed + if(changed?, do: 1, else: 0)
            }}}

        error ->
          {:halt, error}
      end
    end)
  end
end
