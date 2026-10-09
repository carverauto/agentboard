defmodule Agentboard.Delivery.BranchFlow do
  @moduledoc "Bounded, read-only retained branch evidence. No provider calls, enrollment or inferred branch health."
  alias Agentboard.{Repo, SeatScope}
  alias Agentboard.Delivery.{PullRequest, Reads, WorkflowRun}
  alias Agentboard.Delivery.BranchFlow.Route
  alias Agentboard.Board.Operations, as: Ops
  require Ash.Query

  @inventory """
  WITH tracked AS (
    SELECT p.id,p.owner || '/' || p.repo AS repository,s.lifecycle
    FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
    WHERE s.enabled OR s.lifecycle IN ('merged','closed')
  ), eligible AS (
    SELECT repository FROM tracked
    UNION
    SELECT repository FROM delivery_workflow_runs
    WHERE observed_at IS NOT NULL AND NULLIF(branch,'') IS NOT NULL
      AND NULLIF(workflow_id,'') IS NOT NULL AND NULLIF(head_sha,'') IS NOT NULL
      AND repository=lower(repository) AND repository ~ '^[a-z0-9_.-]+/[a-z0-9_.-]+$'
  ), red_counts AS (
    SELECT repository,count(*)::bigint AS red_count FROM delivery_workflow_runs
    WHERE failed_at IS NOT NULL AND resolved_at IS NULL GROUP BY repository
  ), inventory AS (
    SELECT e.repository,
      count(t.id) FILTER (WHERE t.lifecycle='open')::bigint AS open_count,
      count(t.id) FILTER (WHERE t.lifecycle IN ('merged','closed'))::bigint AS terminal_count,
      count(t.id) FILTER (WHERE t.lifecycle IS NULL OR t.lifecycle NOT IN ('open','merged','closed'))::bigint AS unknown_lifecycle_count,
      coalesce(r.red_count,0)::bigint AS red_count
    FROM eligible e LEFT JOIN tracked t ON t.repository=e.repository
    LEFT JOIN red_counts r ON r.repository=e.repository GROUP BY e.repository,r.red_count
  )
  """
  @matched """
  c.id=s.snapshot_id AND c.pull_request_id=p.id AND c.head_sha=s.head_sha
    AND c.base_sha=s.base_sha AND c.observed_at=s.observed_at AND c.generation=s.generation
    AND c.payload->>'base_ref'=s.base_ref
  """
  @summary_fields ~w(repository open_count terminal_count unknown_lifecycle_count red_count)a
  @relation_fields ~w(id url number repository base_repo base_ref base_sha head_repo head_ref head_sha expected_base_sha observed_at snapshot_generation poll_generation metadata_available)a

  def list(params \\ %{}, opts \\ []) do
    params = if is_map(params), do: params, else: %{"repo" => :invalid}

    case Repo.transaction(
           fn ->
             # Every aggregate, selection, record expansion and persistent oldest
             # reads the same MVCC snapshot. READ ONLY is a side-effect backstop.
             Repo.statement!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
             Repo.statement!("SET LOCAL statement_timeout='2000ms'", [])

             %{rows: [[stamp, revision]]} =
               Repo.statement!("SELECT clock_timestamp(),pg_current_snapshot()::text", [])

             overview(params, opts, stamp) |> with_revision(revision)
           end,
           timeout: 20_000
         ) do
      {:ok, result} -> {:ok, result}
      {:error, _} -> {:error, "unavailable", "Branch-flow database reads are unavailable."}
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError, Ash.Error.Invalid, Ash.Error.Unknown] ->
      {:error, "unavailable", "Branch-flow database reads are unavailable."}
  end

  defp overview(params, opts, stamp) do
    normalized = Route.normalize(params)

    filters =
      case normalized do
        {:ok, filters} -> filters
        _ -> params |> Map.take(~w(repo node_kind node view q show_terminal cursor))
      end

    inventory = inventory(opts, stamp)
    cards = inventory.cards
    chooser = chooser(params, stamp)
    table = table(normalized, stamp)
    attention = attention(params, Enum.map(cards, & &1.repository), stamp)
    budget = protected(:budget, &Reads.budget/0)

    Map.merge(inventory, %{
      filters: filters,
      as_of: stamp,
      coverage: "locally_tracked",
      source: "retained_database",
      settings_revision: nil,
      selection: filters,
      github_budget:
        case budget do
          {:ok, value} -> value
          _ -> nil
        end,
      chooser: chooser,
      table: table,
      attention: attention,
      unavailable: [:pins, :branch_roles, :numeric_divergence]
    })
  end

  defp inventory(opts, stamp) do
    held = Keyword.get(opts, :card_repositories)

    held =
      if is_list(held) and length(held) <= 5 and
           Enum.all?(held, &(is_binary(&1) and SeatScope.canonical_repo(&1) == &1)),
         do: Enum.uniq(held),
         else: nil

    result =
      protected(:inventory, fn ->
        %{rows: [[total, ranked, selected]]} =
          Repo.statement!(
            @inventory <>
              """
              , ranked AS (SELECT * FROM inventory ORDER BY open_count DESC,repository LIMIT 5),
              selected AS (
                SELECT i.*,h.ordinality FROM unnest($1::text[]) WITH ORDINALITY h(repository,ordinality)
                LEFT JOIN inventory i ON i.repository=h.repository
              )
              SELECT (SELECT count(*) FROM inventory),
                (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY open_count DESC,repository),'[]'::jsonb) FROM ranked r),
                (SELECT coalesce(jsonb_agg(jsonb_build_object('repository',h.repository,
                  'open_count',s.open_count,'terminal_count',s.terminal_count,
                  'unknown_lifecycle_count',s.unknown_lifecycle_count,'red_count',s.red_count)
                  ORDER BY h.ordinality),'[]'::jsonb)
                  FROM unnest($1::text[]) WITH ORDINALITY h(repository,ordinality)
                  LEFT JOIN selected s ON s.ordinality=h.ordinality)
              """,
            [held || []]
          )

        rows = if is_nil(held), do: ranked, else: selected
        {total, Enum.map(ranked, & &1["repository"]), Enum.map(rows, &summary(&1, stamp))}
      end)

    case result do
      {:ok, {total, ranked, cards}} ->
        relations = protected(:relations, fn -> relations(Enum.map(cards, & &1.repository)) end)

        cards =
          Enum.map(cards, fn card ->
            case relations do
              {:ok, by_repository} ->
                Map.put(card, :relations, Map.get(by_repository, card.repository, []))

              _ ->
                card
                |> Map.put(:relations, [])
                |> Map.put(:relations_error, "Relations unavailable")
            end
          end)

        %{
          cards: cards,
          ranked_repositories: ranked,
          inventory_count: total,
          overflow_count: max(0, total - Enum.count(cards, & &1.available)),
          inventory: metadata(stamp, %{ranking: "tracked_open_count"}) |> Map.put(:error, nil)
        }

      _ ->
        repositories = held || fallback_repositories()

        %{
          cards:
            Enum.map(repositories, fn repository ->
              summary(%{"repository" => repository}, stamp)
              |> Map.merge(%{
                available: is_nil(held),
                counts_available: false,
                error:
                  if(is_nil(held),
                    do: "Repository counts unavailable",
                    else: "Repository eligibility and counts unavailable"
                  )
              })
            end),
          ranked_repositories: repositories,
          inventory_count: nil,
          overflow_count: nil,
          inventory:
            metadata(stamp, %{ranking: "unavailable_alphabetical_fallback"})
            |> Map.merge(%{
              error: "Repository counts unavailable; bounded alphabetical fallback",
              partial: true
            })
        }
    end
  end

  defp fallback_repositories(search \\ "", offset \\ 0, limit \\ 5) do
    case protected(:inventory_fallback, fn ->
           %{rows: rows} =
             Repo.statement!(
               """
               SELECT repository FROM (
                 SELECT p.owner || '/' || p.repo AS repository FROM delivery_pull_requests p
                   JOIN delivery_poll_states s ON s.id=p.id WHERE s.enabled OR s.lifecycle IN ('merged','closed')
                 UNION
                 SELECT repository FROM delivery_workflow_runs WHERE observed_at IS NOT NULL
                   AND NULLIF(branch,'') IS NOT NULL AND NULLIF(workflow_id,'') IS NOT NULL
                   AND NULLIF(head_sha,'') IS NOT NULL AND repository=lower(repository)
                   AND repository ~ '^[a-z0-9_.-]+/[a-z0-9_.-]+$'
               ) eligible WHERE position(lower($1) in repository)>0 ORDER BY repository LIMIT $2 OFFSET $3
               """,
               [search, limit, offset]
             )

           List.flatten(rows)
         end) do
      {:ok, repositories} -> repositories
      _ -> []
    end
  end

  defp summary(row, stamp) do
    Map.new(@summary_fields, &{&1, row[Atom.to_string(&1)]})
    |> Map.merge(metadata(stamp, %{repository: row["repository"]}))
    |> Map.merge(%{
      available: not is_nil(row["open_count"]),
      counts_available: not is_nil(row["open_count"]),
      error: if(is_nil(row["open_count"]), do: "Repository no longer in tracked inventory"),
      relations: [],
      default_branch: nil,
      integration_branch: nil,
      branch_health: "unknown",
      numeric_divergence: nil
    })
  end

  defp relations(repositories) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT relation.* FROM unnest($1::text[]) wanted(repository)
        CROSS JOIN LATERAL (
          SELECT p.id,p.url,p.number,p.owner || '/' || p.repo AS repository,
            p.owner || '/' || p.repo AS base_repo,c.payload->>'base_ref' AS base_ref,c.base_sha,
            c.payload->>'head_repo' AS head_repo,c.payload->>'head_ref' AS head_ref,c.head_sha,
            s.expected_base_sha,c.observed_at,c.generation AS snapshot_generation,
            s.generation AS poll_generation,c.id IS NOT NULL AS metadata_available
          FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
          LEFT JOIN delivery_ci_snapshots c ON #{@matched}
          WHERE p.owner || '/' || p.repo=wanted.repository AND s.enabled AND s.lifecycle='open'
          ORDER BY p.id LIMIT 3
        ) relation ORDER BY relation.repository,relation.id
        """,
        [repositories]
      )

    rows
    |> Enum.map(&(Enum.zip(@relation_fields, &1) |> Map.new()))
    |> Enum.group_by(& &1.repository)
  end

  defp chooser(params, stamp) do
    with {:ok, search} <- Route.search(params["chooser_q"]),
         filters = %{"chooser_q" => search},
         {:ok, offset} <- Route.offset(params["chooser_cursor"], "chooser", filters) do
      result =
        protected(:chooser, fn ->
          %{rows: [[total, rows]]} =
            Repo.statement!(
              @inventory <>
                """
                , matching AS (SELECT * FROM inventory WHERE position(lower($1) in repository)>0)
                SELECT (SELECT count(*) FROM matching),
                  (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY repository),'[]'::jsonb)
                    FROM (SELECT * FROM matching ORDER BY repository LIMIT 20 OFFSET $2) r)
                """,
              [search, offset]
            )

          {total, Enum.map(rows, &summary(&1, stamp))}
        end)

      case result do
        {:ok, {total, rows}} ->
          page("chooser", filters, offset, total, stamp)
          |> Map.put(:repositories, rows)
          |> Map.put(:error, expired_page(offset, total))

        _ ->
          rows = fallback_repositories(search, offset, 21)

          page("chooser", filters, offset, nil, stamp)
          |> with_more("chooser", filters, offset, length(rows) > 20)
          |> Map.put(
            :repositories,
            Enum.map(Enum.take(rows, 20), fn repository ->
              summary(%{"repository" => repository}, stamp)
              |> Map.merge(%{
                available: true,
                counts_available: false,
                error: "Repository counts unavailable"
              })
            end)
          )
          |> Map.put(:error, "Repository counts unavailable; bounded alphabetical fallback")
      end
    else
      {:error, error} -> empty_section(:repositories, stamp, error)
    end
  end

  defp table({:error, error}, stamp), do: empty_section(:prs, stamp, error)

  defp table({:ok, filters}, stamp) do
    with {:ok, offset} <- Route.offset(filters["cursor"], "table", filters) do
      case protected(:table, fn -> table_page(filters, offset, stamp) end) do
        {:ok, result} -> result
        _ -> empty_section(:prs, stamp, "Tracked PR records unavailable")
      end
    else
      {:error, error} -> empty_section(:prs, stamp, error)
    end
  end

  defp table_page(filters, offset, stamp) do
    repo = filters["repo"]
    kind = filters["node_kind"]
    node = filters["node"]
    q = filters["q"] || ""
    terminal = filters["show_terminal"] == "true"

    case valid_selection(repo, kind, node) do
      :ok ->
        args = [repo, kind, node, q, terminal]

        where = """
        FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
        LEFT JOIN delivery_ci_snapshots c ON #{@matched}
        WHERE (s.enabled OR s.lifecycle IN ('merged','closed'))
          AND ($1::text IS NULL OR p.owner || '/' || p.repo=$1)
          AND ($2::text IS DISTINCT FROM 'base' OR s.base_ref=$3)
          AND ($2::text IS DISTINCT FROM 'pr' OR p.id=$3)
          AND ($5::boolean OR s.lifecycle IS NULL OR s.lifecycle NOT IN ('merged','closed'))
          AND ($4='' OR position($4 in p.number)>0 OR position($4 in coalesce(s.base_ref,''))>0
            OR position($4 in coalesce(c.payload->>'head_ref',''))>0)
        """

        total =
          case protected(:table_count, fn ->
                 %{rows: [[count]]} = Repo.statement!("SELECT count(*) " <> where, args)
                 count
               end) do
            {:ok, count} -> count
            _ -> nil
          end

        %{rows: ids} =
          Repo.statement!(
            "SELECT p.id,c.id IS NOT NULL " <> where <> " ORDER BY p.id LIMIT 21 OFFSET $6",
            args ++ [offset]
          )

        more? = length(ids) > 20
        proof = ids |> Enum.take(20) |> Map.new(fn [id, matched] -> {id, matched} end)
        ids = Map.keys(proof)

        prs =
          PullRequest
          |> Ash.Query.filter(id in ^ids)
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.limit(20)
          |> Ash.read!()
          |> Reads.records()
          |> Enum.map(&qualify_source(&1, proof[&1.pr["id"]]))

        page("table", filters, offset, total, stamp)
        |> with_more("table", filters, offset, more?)
        |> Map.put(:prs, prs)
        |> Map.put(:error, expired_page(offset, total))

      {:error, error} ->
        empty_section(:prs, stamp, error)
    end
  end

  # The preview fails closed when its exact-source join cannot prove that the
  # retained snapshot belongs to this poll revision. This is a consumer guard,
  # not a replacement producer/currentness policy. Failure obligations and their
  # owners remain intact; historical red is never resolved by a view action.
  defp qualify_source(row, true), do: Map.put(row, :source_currentness_error, nil)

  defp qualify_source(row, _) do
    Map.merge(row, %{
      fresh: false,
      ci_state: if(row.ci_state == "failing", do: "failing", else: "unknown"),
      merge_state: if(row.merge_state == "conflicting", do: "stale", else: "unknown"),
      mergeable: nil,
      mergeable_state: nil,
      base_ref: nil,
      draft: nil,
      source_currentness_error:
        "Exact snapshot proof missing or mismatched (PR, head, base, observation, generation or ref). Retained failure obligations are unchanged."
    })
  end

  defp valid_selection(nil, _, _), do: :ok

  defp valid_selection(repo, kind, node) do
    %{rows: [[eligible]]} =
      Repo.statement!(
        @inventory <>
          " SELECT EXISTS(SELECT 1 FROM inventory WHERE repository=$1)",
        [repo]
      )

    cond do
      not eligible ->
        {:error, "Repository is not in the locally tracked inventory."}

      kind == "pr" ->
        %{rows: [[exists]]} =
          Repo.statement!(
            """
            SELECT EXISTS(SELECT 1 FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
              WHERE p.id=$1 AND p.owner || '/' || p.repo=$2 AND (s.enabled OR s.lifecycle IN ('merged','closed')))
            """,
            [node, repo]
          )

        if exists,
          do: :ok,
          else: {:error, "PR does not belong to the selected tracked repository."}

      kind == "base" ->
        %{rows: [[exists]]} =
          Repo.statement!(
            """
            SELECT EXISTS(SELECT 1 FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
              WHERE p.owner || '/' || p.repo=$1 AND s.base_ref=$2
                AND (s.enabled OR s.lifecycle IN ('merged','closed')))
            """,
            [repo, node]
          )

        if exists,
          do: :ok,
          else: {:error, "Base reference is not retained for the selected tracked repository."}

      true ->
        :ok
    end
  end

  defp attention(params, card_repositories, stamp) do
    filters = %{}

    base =
      metadata(stamp, %{scope: "all_retained_red"})
      |> Map.merge(%{
        enabled: Agentboard.Delivery.Scheduling.enabled?(),
        runs: [],
        oldest: nil,
        total: nil,
        previous_cursor: nil,
        next_cursor: nil,
        error: nil,
        count_available: false
      })

    count =
      protected(:attention_count, fn ->
        %{rows: [[count]]} =
          Repo.statement!(
            "SELECT count(*) FROM delivery_workflow_runs WHERE failed_at IS NOT NULL AND resolved_at IS NULL",
            []
          )

        count
      end)

    oldest =
      protected(:attention_oldest, fn ->
        attention_rows(0, 1) |> Enum.map(&run(&1, card_repositories, stamp)) |> List.first()
      end)

    base =
      base
      |> Map.put(
        :total,
        case count do
          {:ok, n} -> n
          _ -> nil
        end
      )
      |> Map.put(:count_available, match?({:ok, _}, count))
      |> Map.put(
        :oldest,
        case oldest do
          {:ok, row} -> row
          _ -> nil
        end
      )
      |> Map.put(:oldest_available, match?({:ok, _}, oldest))

    with {:ok, offset} <- Route.offset(params["attention_cursor"], "attention", filters),
         {:ok, rows} <- protected(:attention_rows, fn -> attention_rows(offset, 11) end) do
      Map.merge(base, page("attention", filters, offset, base.total, stamp))
      |> with_more("attention", filters, offset, length(rows) > 10)
      |> Map.put(:runs, rows |> Enum.take(10) |> Enum.map(&run(&1, card_repositories, stamp)))
      |> Map.put(:error, expired_page(offset, base.total))
    else
      {:error, error} when is_binary(error) -> Map.put(base, :error, error)
      _ -> Map.put(base, :error, "Retained workflow details unavailable")
    end
  end

  defp attention_rows(offset, limit) do
    WorkflowRun
    |> Ash.Query.filter(not is_nil(failed_at) and is_nil(resolved_at))
    |> Ash.Query.sort(failed_at: :asc, id: :asc)
    |> Ash.Query.offset(offset)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
  end

  defp run(row, card_repositories, stamp) do
    Ops.public(row)
    |> Map.merge(%{
      red_age: age(stamp, row.failed_at),
      observation_age: age(stamp, row.observed_at),
      stale: is_nil(row.observed_at) or age(stamp, row.observed_at) > 180,
      deferred: not is_nil(row.last_error),
      outside_strip: row.repository not in card_repositories,
      routing:
        if(row.responsible_id, do: "retained_owner", else: "missing_coordinator_captain_queue")
    })
  end

  defp age(_, nil), do: nil
  defp age(stamp, observed), do: max(0, DateTime.diff(stamp, observed))

  defp page(section, filters, offset, total, stamp) do
    size = if section == "attention", do: 10, else: 20

    metadata(stamp, filters)
    |> Map.merge(%{
      total: total,
      count_available: is_integer(total),
      offset: offset,
      previous_cursor: if(offset > 0, do: Route.cursor(section, max(0, offset - size), filters)),
      next_cursor:
        if(is_integer(total) and offset + size < total,
          do: Route.cursor(section, offset + size, filters)
        ),
      error: nil
    })
  end

  defp with_more(page, section, filters, offset, more?) do
    size = if section == "attention", do: 10, else: 20
    Map.put(page, :next_cursor, if(more?, do: Route.cursor(section, offset + size, filters)))
  end

  defp expired_page(offset, total) when is_integer(total) and offset > 0 and offset >= total,
    do: "This page is no longer available. Reset this page to continue."

  defp expired_page(_, _), do: nil

  defp empty_section(key, stamp, error) do
    metadata(stamp, %{})
    |> Map.merge(%{
      key => [],
      total: nil,
      offset: 0,
      count_available: false,
      previous_cursor: nil,
      next_cursor: nil,
      error: error
    })
  end

  defp with_revision(result, revision) do
    result = Map.put(result, :projection_revision, revision)

    result =
      Enum.reduce([:inventory, :chooser, :table, :attention], result, fn section, acc ->
        Map.update!(acc, section, &Map.put(&1, :projection_revision, revision))
      end)

    Map.update!(
      result,
      :cards,
      &Enum.map(&1, fn card -> Map.put(card, :projection_revision, revision) end)
    )
  end

  defp metadata(stamp, selection),
    do: %{
      as_of: stamp,
      coverage: "locally_tracked",
      source: "retained_database",
      selection: selection,
      settings_revision: nil
    }

  # Savepoints keep a timed-out optional aggregate from poisoning the other
  # independent sections of the read-only snapshot. Names are compile-time atoms.
  defp protected(name, fun) do
    savepoint = "branch_flow_" <> Atom.to_string(name)
    Repo.statement!("SAVEPOINT " <> savepoint, [])

    try do
      value = fun.()
      Repo.statement!("RELEASE SAVEPOINT " <> savepoint, [])
      {:ok, value}
    rescue
      _ in [Postgrex.Error, DBConnection.ConnectionError, Ash.Error.Invalid, Ash.Error.Unknown] ->
        Repo.statement!("ROLLBACK TO SAVEPOINT " <> savepoint, [])
        Repo.statement!("RELEASE SAVEPOINT " <> savepoint, [])
        {:error, :unavailable}
    end
  end
end
