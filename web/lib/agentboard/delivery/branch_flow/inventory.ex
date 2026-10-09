defmodule Agentboard.Delivery.BranchFlow.Inventory do
  @moduledoc "Shared local eligibility and bounded repository chooser; never expands PR projections."
  alias Agentboard.Repo
  alias Agentboard.Delivery.BranchFlow.Route

  @sql """
  WITH tracked AS (
    SELECT p.id,p.owner || '/' || p.repo AS repository,s.lifecycle
    FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
    WHERE s.enabled OR s.lifecycle IN ('merged','closed')
  ), eligible_candidates AS (
    SELECT repository FROM tracked
    UNION
    SELECT repository FROM delivery_workflow_runs
    WHERE observed_at IS NOT NULL AND NULLIF(branch,'') IS NOT NULL
      AND NULLIF(workflow_id,'') IS NOT NULL AND NULLIF(head_sha,'') IS NOT NULL
  ), eligible AS (
    SELECT repository FROM eligible_candidates
    WHERE repository=lower(repository) AND octet_length(repository)<=256
      AND repository ~ '^[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+$'
      AND split_part(repository,'/',2) NOT IN ('.','..')
  ), red_counts AS (
    SELECT repository,count(*)::bigint AS red_count FROM delivery_workflow_runs
    WHERE failed_at IS NOT NULL AND resolved_at IS NULL GROUP BY repository
  ), tracked_counts AS (
    SELECT repository,
      count(*) FILTER (WHERE lifecycle='open')::bigint AS open_count,
      count(*) FILTER (WHERE lifecycle IN ('merged','closed'))::bigint AS terminal_count,
      count(*) FILTER (WHERE lifecycle IS NULL OR lifecycle NOT IN ('open','merged','closed'))::bigint AS unknown_lifecycle_count
    FROM tracked GROUP BY repository
  ), inventory AS (
    SELECT e.repository,coalesce(t.open_count,0)::bigint AS open_count,
      coalesce(t.terminal_count,0)::bigint AS terminal_count,
      coalesce(t.unknown_lifecycle_count,0)::bigint AS unknown_lifecycle_count,
      coalesce(r.red_count,0)::bigint AS red_count
    FROM eligible e LEFT JOIN tracked_counts t ON t.repository=e.repository
    LEFT JOIN red_counts r ON r.repository=e.repository
  )
  """

  def sql, do: @sql

  # The eligible CTE has no aggregate or projection dependency. Both validation
  # and alphabetical degradation use the exact same retained inventory contract.
  @eligible @sql |> String.split(", red_counts AS (") |> hd()

  def present(repositories) when is_list(repositories) and length(repositories) <= 5 do
    %{rows: rows} =
      Repo.statement!(
        @eligible <>
          " SELECT repository FROM eligible WHERE repository=ANY($1::text[]) ORDER BY repository",
        [repositories]
      )

    List.flatten(rows)
  end

  def fallback(search \\ "", offset \\ 0, limit \\ 5, pins \\ []) do
    %{rows: rows} =
      Repo.statement!(
        @eligible <>
          """
          SELECT e.repository FROM eligible e
          LEFT JOIN unnest($4::text[]) WITH ORDINALITY pin(repository,ordinality)
            ON pin.repository=e.repository
          WHERE position(lower($1) in e.repository)>0
          ORDER BY pin.ordinality NULLS LAST,e.repository LIMIT $2 OFFSET $3
          """,
        [search, limit, offset, pins]
      )

    List.flatten(rows)
  end

  def chooser(params \\ %{}) do
    case Repo.transaction(fn ->
           Repo.statement!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
           Repo.statement!("SET LOCAL statement_timeout='2000ms'", [])
           chooser_in_snapshot(params)
         end) do
      {:ok, result} -> result
      _ -> empty("Repository inventory unavailable; saved pins are unchanged")
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      empty("Repository inventory unavailable; saved pins are unchanged")
  end

  def chooser_in_snapshot(params) when is_map(params) do
    with {:ok, search} <- Route.search(params["chooser_q"]),
         filters = %{"chooser_q" => search},
         {:ok, offset} <- Route.offset(params["chooser_cursor"], "chooser", filters) do
      result =
        protected(fn ->
          %{rows: [[total, rows]]} =
            Repo.statement!(
              @sql <>
                """
                , matching AS (SELECT * FROM inventory WHERE position(lower($1) in repository)>0)
                SELECT (SELECT count(*) FROM matching),
                  (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY repository),'[]'::jsonb)
                    FROM (SELECT * FROM matching ORDER BY repository LIMIT 20 OFFSET $2) r)
                """,
              [search, offset]
            )

          {total, rows}
        end)

      case result do
        {:ok, {total, rows}} ->
          page(filters, offset, total, offset + 20 < total)
          |> Map.put(:repositories, Enum.map(rows, &summary/1))
          |> Map.put(
            :error,
            if(offset > 0 and offset >= total,
              do: "This page is no longer available. Reset this page to continue."
            )
          )

        _ ->
          case protected(fn -> fallback(search, offset, 21) end) do
            {:ok, repos} ->
              page(filters, offset, nil, length(repos) > 20)
              |> Map.put(
                :repositories,
                Enum.map(
                  Enum.take(repos, 20),
                  &summary(%{"repository" => &1})
                )
              )
              |> Map.put(:error, "Repository counts unavailable; bounded alphabetical fallback")

            _ ->
              empty("Repository inventory unavailable; saved pins are unchanged")
          end
      end
    else
      {:error, error} -> empty(error)
    end
  end

  def chooser_in_snapshot(_), do: empty("Invalid repository chooser input")

  defp summary(row),
    do:
      Map.new(
        ~w(repository open_count terminal_count unknown_lifecycle_count red_count)a,
        &{&1, row[Atom.to_string(&1)]}
      )

  defp page(filters, offset, total, more?),
    do: %{
      total: total,
      offset: offset,
      count_available: is_integer(total),
      previous_cursor: if(offset > 0, do: Route.cursor("chooser", offset - 20, filters)),
      next_cursor: if(more?, do: Route.cursor("chooser", offset + 20, filters)),
      error: nil
    }

  defp empty(error),
    do: %{
      repositories: [],
      total: nil,
      offset: 0,
      count_available: false,
      previous_cursor: nil,
      next_cursor: nil,
      error: error
    }

  defp protected(fun) do
    Repo.statement!("SAVEPOINT branch_flow_inventory_chooser", [])

    try do
      result = fun.()
      Repo.statement!("RELEASE SAVEPOINT branch_flow_inventory_chooser", [])
      {:ok, result}
    rescue
      _ in [Postgrex.Error, DBConnection.ConnectionError] ->
        Repo.statement!("ROLLBACK TO SAVEPOINT branch_flow_inventory_chooser", [])
        Repo.statement!("RELEASE SAVEPOINT branch_flow_inventory_chooser", [])
        {:error, :unavailable}
    end
  end
end
