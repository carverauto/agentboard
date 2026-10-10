defmodule Agentboard.Delivery.BranchFlow do
  @moduledoc "Bounded, read-only retained branch evidence. No provider calls, enrollment or inferred branch health."
  alias Agentboard.{Repo, SeatScope}
  alias Agentboard.Delivery.{PullRequest, Reads, WorkflowRun}
  alias Agentboard.Delivery.BranchFlow.{Inventory, Relations, RepositoryRoles, Route, Settings}
  alias Agentboard.Board.Operations, as: Ops
  require Ash.Query
  require Ecto.Query

  @inventory Inventory.sql()
  @matched Relations.matched_sql()
  @summary_fields ~w(repository open_count terminal_count unknown_lifecycle_count red_count)a

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
        {:ok, filters} ->
          filters

        _ ->
          params |> Map.take(~w(repo node_kind node view q show_terminal cursor topology_cursor))
      end

    settings = protected(:settings, &Settings.read/0)

    pins =
      case settings do
        {:ok, config} -> config["pinned_repositories"]
        _ -> []
      end

    inventory = inventory(opts, stamp, pins)
    # An unavailable settings read cannot be interpreted as an empty pin list or
    # offer an implicit pinless reorder over a last-known strip.
    inventory =
      if match?({:ok, _}, settings),
        do: inventory,
        else: Map.put(inventory, :ranked_repositories, Enum.map(inventory.cards, & &1.repository))

    cards = inventory.cards
    chooser = chooser(params, stamp)
    table = table(normalized, stamp)
    topology = topology(normalized, stamp)
    inspection = inspection(opts, table, topology, stamp)

    {inventory, topology, inspection, roles} =
      repository_roles(inventory, topology, inspection, filters, stamp)

    attention = attention(params, Enum.map(cards, & &1.repository), stamp)
    budget = protected(:budget, &Reads.budget/0)

    Map.merge(inventory, %{
      filters: filters,
      as_of: stamp,
      coverage: "locally_tracked",
      source: "retained_database",
      settings_revision:
        case settings do
          {:ok, config} -> config["revision"]
          _ -> nil
        end,
      settings:
        case settings do
          {:ok, config} ->
            %{
              available: true,
              pinned_repositories: pins,
              error: nil,
              revision: config["revision"]
            }

          _ ->
            %{
              available: false,
              pinned_repositories: nil,
              revision: nil,
              error:
                "Captain pin order unavailable; showing last-known cards or degraded busiest fallback"
            }
        end,
      selection: filters,
      github_budget:
        case budget do
          {:ok, value} -> value
          _ -> nil
        end,
      chooser: chooser,
      table: table,
      topology: topology,
      inspection: inspection,
      repository_roles: roles,
      attention: attention,
      unavailable: [:integration_role, :numeric_divergence]
    })
  end

  defp repository_roles(inventory, topology, inspection, filters, stamp) do
    selected = filters["repo"]
    inspected = if inspection && inspection.available, do: inspection.relation.repository

    repositories =
      (Enum.map(inventory.cards, & &1.repository) ++ [selected, inspected])
      |> Enum.filter(&(is_binary(&1) and SeatScope.canonical_repo(&1) == &1))
      |> Enum.uniq()

    # Five cards, one selected topology repo and one inspected repo. Roles never
    # enlarge inventory or hydrate all table relations. A broken optional metadata
    # read must not hide retained-red attention or the existing PR projection.
    roles =
      case protected(:repository_roles, fn -> RepositoryRoles.load(repositories, stamp) end) do
        {:ok, values} ->
          values

        _ ->
          Map.new(repositories, fn repository ->
            role = RepositoryRoles.qualify(repository, nil, stamp, false)
            {repository, %{role | reason: "read_unavailable"}}
          end)
      end

    cards =
      Enum.map(inventory.cards, fn card ->
        role = Map.get(roles, card.repository)

        card
        |> Map.put(:repository_role, role)
        |> Map.put(:default_branch, if(role, do: role.default_ref))
      end)

    topology = Map.put(topology, :repository_role, Map.get(roles, selected))

    inspection =
      if inspection, do: Map.put(inspection, :repository_role, Map.get(roles, inspected))

    {Map.put(inventory, :cards, cards), topology, inspection, roles}
  end

  defp inventory(opts, stamp, pins) do
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
              , prioritized AS (
                SELECT i.*,pin.ordinality AS pin_position FROM inventory i
                LEFT JOIN unnest($2::text[]) WITH ORDINALITY pin(repository,ordinality)
                  ON pin.repository=i.repository
              ), ranked AS (
                SELECT * FROM prioritized
                ORDER BY pin_position NULLS LAST,open_count DESC,repository LIMIT 5
              ), selected AS (
                SELECT i.*,h.ordinality FROM unnest($1::text[]) WITH ORDINALITY h(repository,ordinality)
                LEFT JOIN prioritized i ON i.repository=h.repository
              )
              SELECT (SELECT count(*) FROM inventory),
                (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY pin_position NULLS LAST,open_count DESC,repository),'[]'::jsonb) FROM ranked r),
                (SELECT coalesce(jsonb_agg(jsonb_build_object('repository',h.repository,
                  'open_count',s.open_count,'terminal_count',s.terminal_count,
                  'unknown_lifecycle_count',s.unknown_lifecycle_count,'red_count',s.red_count,
                  'pin_position',s.pin_position)
                  ORDER BY h.ordinality),'[]'::jsonb)
                  FROM unnest($1::text[]) WITH ORDINALITY h(repository,ordinality)
                  LEFT JOIN selected s ON s.ordinality=h.ordinality)
              """,
            [held || [], pins]
          )

        rows = if is_nil(held), do: ranked, else: selected
        {total, Enum.map(ranked, & &1["repository"]), Enum.map(rows, &summary(&1, stamp))}
      end)

    case result do
      {:ok, {total, ranked, cards}} ->
        relations =
          protected(:relations, fn -> relations(Enum.map(cards, & &1.repository), stamp) end)

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
          inventory:
            metadata(stamp, %{ranking: "captain_pins_then_tracked_open_count"})
            |> Map.put(:error, nil)
        }

      _ ->
        ranked = fallback_repositories("", 0, 5, pins)
        repositories = held || ranked

        %{
          cards:
            Enum.map(repositories, fn repository ->
              summary(%{"repository" => repository}, stamp)
              |> Map.put(:pin_position, pin_position(pins, repository))
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
          ranked_repositories: ranked,
          inventory_count: nil,
          overflow_count: nil,
          inventory:
            metadata(stamp, %{ranking: "captain_pins_then_alphabetical_fallback"})
            |> Map.merge(%{
              error: "Repository counts unavailable; bounded alphabetical fallback",
              partial: true
            })
        }
    end
  end

  defp fallback_repositories(search, offset, limit, pins) do
    case protected(:inventory_fallback, fn -> Inventory.fallback(search, offset, limit, pins) end) do
      {:ok, repositories} -> repositories
      _ -> []
    end
  end

  defp pin_position(pins, repository) do
    case Enum.find_index(pins, &(&1 == repository)) do
      nil -> nil
      index -> index + 1
    end
  end

  defp summary(row, stamp) do
    Map.new(@summary_fields, &{&1, row[Atom.to_string(&1)]})
    |> Map.merge(metadata(stamp, %{repository: row["repository"]}))
    |> Map.merge(%{
      pin_position: row["pin_position"],
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

  defp relations(repositories, stamp) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT relation.id FROM unnest($1::text[]) wanted(repository)
        CROSS JOIN LATERAL (
          SELECT p.id FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
          WHERE p.owner || '/' || p.repo=wanted.repository AND s.enabled AND s.lifecycle='open'
          ORDER BY p.id LIMIT 3
        ) relation ORDER BY wanted.repository,relation.id
        """,
        [repositories]
      )

    rows |> List.flatten() |> Relations.load(stamp) |> Enum.group_by(& &1.repository)
  end

  defp chooser(params, stamp) do
    Inventory.chooser_in_snapshot(params)
    |> Map.merge(metadata(stamp, Map.take(params, ["chooser_q"])))
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
            "SELECT p.id " <> where <> " ORDER BY p.id LIMIT 21 OFFSET $6",
            args ++ [offset]
          )

        more? = length(ids) > 20
        ids = ids |> Enum.take(20) |> List.flatten()

        prs =
          PullRequest
          |> Ash.Query.filter(id in ^ids)
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.limit(20)
          |> Ash.read!()
          |> Reads.records(branch_flow: true, as_of: stamp)
          |> Enum.map(&Relations.qualify/1)

        page("table", filters, offset, total, stamp)
        |> with_more("table", filters, offset, more?)
        |> Map.put(:prs, prs)
        |> Map.put(:error, expired_page(offset, total))

      {:error, error} ->
        empty_section(:prs, stamp, error)
    end
  end

  defp topology({:error, error}, stamp), do: empty_section(:relations, stamp, error)

  defp topology({:ok, filters}, stamp) do
    if is_nil(filters["repo"]) do
      empty_section(:relations, stamp, nil)
    else
      with {:ok, offset} <- Route.offset(filters["topology_cursor"], "topology", filters),
           {:ok, result} <- protected(:topology, fn -> topology_page(filters, offset, stamp) end) do
        result
      else
        {:error, error} when is_binary(error) -> empty_section(:relations, stamp, error)
        _ -> empty_section(:relations, stamp, "Observed PR relationships unavailable")
      end
    end
  end

  defp topology_page(filters, offset, stamp) do
    case valid_selection(filters["repo"], filters["node_kind"], filters["node"]) do
      :ok ->
        args = [filters["repo"], filters["node_kind"], filters["node"]]

        where = """
        FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
        WHERE s.enabled AND s.lifecycle='open' AND p.owner || '/' || p.repo=$1
          AND ($2::text IS DISTINCT FROM 'base' OR s.base_ref=$3)
          AND ($2::text IS DISTINCT FROM 'pr' OR p.id=$3)
        """

        total =
          case protected(:topology_count, fn ->
                 %{rows: [[count]]} = Repo.statement!("SELECT count(*) " <> where, args)
                 count
               end) do
            {:ok, count} -> count
            _ -> nil
          end

        %{rows: ids} =
          Repo.statement!(
            "SELECT p.id " <> where <> " ORDER BY p.id LIMIT 21 OFFSET $4",
            args ++ [offset]
          )

        relations = ids |> Enum.take(20) |> List.flatten() |> Relations.load(stamp)

        {relations, continuation_error} =
          case protected(:topology_continuations, fn ->
                 Relations.with_continuations(relations)
               end) do
            {:ok, values} -> {values, nil}
            _ -> {relations, "Off-page relationship lookup unavailable"}
          end

        page("topology", filters, offset, total, stamp)
        |> with_more("topology", filters, offset, length(ids) > 20)
        |> Map.put(:relations, relations)
        |> Map.put(:error, expired_page(offset, total) || continuation_error)

      {:error, error} ->
        empty_section(:relations, stamp, error)
    end
  end

  defp inspection(opts, table, topology, stamp) do
    id = Keyword.get(opts, :inspection_id)
    mode = Keyword.get(opts, :inspection_mode)

    if is_nil(id) do
      nil
    else
      base =
        metadata(stamp, %{id: id, mode: mode})
        |> Map.merge(%{
          id: id,
          mode: mode,
          available: false,
          record: nil,
          relation: nil,
          failures: [],
          failures_truncated: false,
          sources: [],
          sources_truncated: false,
          detail_path: if(is_binary(id), do: "/prs/" <> URI.encode_www_form(id)),
          error: "Selected PR is not available on this page."
        })

      row = if mode == "table", do: Enum.find(table.prs, &(&1.pr["id"] == id))
      relation = if mode == "topology", do: Enum.find(topology.relations, &(&1.id == id))

      if is_binary(id) and byte_size(id) == 64 and (row || relation) do
        case protected(:inspection, fn -> inspection_record(id, row, relation, base) end) do
          {:ok, result} -> result
          _ -> Map.put(base, :error, "Selected PR inspection unavailable")
        end
      else
        base
      end
    end
  end

  defp inspection_record(id, row, relation, base) do
    # Reuse the table's already loaded record. A topology selection expands just
    # this one PR, never all graph nodes and never the unbounded detail history.
    row =
      row ||
        PullRequest
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.limit(1)
        |> Ash.read!()
        |> Reads.records(branch_flow: true, as_of: base.as_of)
        |> Enum.map(&Relations.qualify/1)
        |> List.first()

    if row do
      failures = protected(:inspection_failures, fn -> Relations.failures(id) end)
      sources = protected(:inspection_sources, fn -> inspection_sources(id) end)

      {failure_rows, failures_truncated} =
        case failures do
          {:ok, value} -> value
          _ -> {[], false}
        end

      {source_rows, sources_truncated} =
        case sources do
          {:ok, value} -> value
          _ -> {[], false}
        end

      Map.merge(base, %{
        available: true,
        record: row,
        relation: relation || row.relation,
        failures: failure_rows,
        failures_truncated: failures_truncated,
        sources: source_rows,
        sources_truncated: sources_truncated,
        error:
          if(match?({:ok, _}, failures) and match?({:ok, _}, sources),
            do: nil,
            else:
              "Some retained failure or submission sources are unavailable; full details may be incomplete."
          )
      })
    else
      base
    end
  end

  defp inspection_sources(id) do
    rows =
      Repo.all(
        Ecto.Query.from(source in Agentboard.Delivery.TaskLink,
          where: source.pull_request_id == ^id,
          order_by: [asc: source.id],
          limit: 11
        )
      )

    {rows |> Enum.take(10) |> Enum.map(&Ops.public/1), length(rows) > 10}
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
    # Keep optional read failures inside our section savepoint. WorkflowRun's
    # default read has no policies/preparations; this Ecto schema read returns
    # the same resource fields without Ash aborting the outer snapshot on error.
    Repo.all(
      Ecto.Query.from(run in WorkflowRun,
        where: not is_nil(run.failed_at) and is_nil(run.resolved_at),
        order_by: [asc: run.failed_at, asc: run.id],
        offset: ^offset,
        limit: ^limit
      )
    )
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
      Enum.reduce(
        [:inventory, :chooser, :table, :topology, :attention, :inspection],
        result,
        fn section, acc ->
          Map.update!(acc, section, fn value ->
            if value do
              value
              |> Map.put(:projection_revision, revision)
              |> Map.put(:settings_revision, result.settings_revision)
            end
          end)
        end
      )

    Map.update!(
      result,
      :cards,
      &Enum.map(&1, fn card ->
        card
        |> Map.put(:projection_revision, revision)
        |> Map.put(:settings_revision, result.settings_revision)
      end)
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
