defmodule Agentboard.FleetStatus do
  @moduledoc """
  Bounded per-fleet status digest for `GET /api/v1/fleet/status`.

  Each fleet reports live seats, the captain's requested and maximum seats,
  backlog, refill, launch intents by state (including dry-run would-launch
  intents), CI obligations, and recent intake for that fleet's repositories.
  The digest never includes message bodies, card or issue descriptions,
  credentials, or lease paths.
  """
  alias Agentboard.{Availability, FleetRefill, Input, Intake, Repo, SeatScope}
  alias Agentboard.Board.{Operations, Reads}
  alias Agentboard.Board.Resources.Agent
  alias Agentboard.FleetLoadout.{Activation, Configuration}
  alias Agentboard.FleetRefill.{Assignment, Pass}
  require Ash.Query

  @fleet_limit 100
  @item_limit 50
  @intake_limit 25
  @intent_states ~w(dry_run pending reserved uncertain launched failed expired superseded closed abandoned)
  @intent_columns ~w(id seat_id agent_id harness host_id loadout_revision state reason workspace_id tab_id pane_id created_at updated_at reserved_at launched_at closed_at)

  def status(params \\ %{}) do
    with :ok <- validate_params(params),
         {:ok, stale_after} <- Reads.roster_threshold() do
      Operations.transaction(fn ->
        now = Operations.now()
        loadouts = load_fleets!(params["fleet_id"])
        context = %{now: now, stale_after: stale_after}

        %{
          "as_of" => DateTime.to_iso8601(now),
          "refill_enabled" => FleetRefill.enabled?(),
          "intake_enabled" => Intake.enabled?(),
          "fleets" => Enum.map(loadouts, &fleet_digest(&1, context))
        }
      end)
    end
  end

  defp validate_params(params) when is_map(params) do
    cond do
      Enum.any?(Map.keys(params), &(&1 != "fleet_id")) ->
        {:error, "invalid_input", "fleet/status accepts only an optional fleet_id filter"}

      Map.has_key?(params, "fleet_id") and not Input.slug?(params["fleet_id"]) ->
        {:error, "invalid_input", "Invalid fleet_id filter"}

      true ->
        :ok
    end
  end

  defp validate_params(_),
    do: {:error, "invalid_input", "fleet/status query parameters must be an object"}

  defp load_fleets!(nil) do
    Configuration
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(@fleet_limit)
    |> Ash.read!()
  end

  defp load_fleets!(fleet_id) do
    case Ash.get!(Configuration, fleet_id, not_found_error?: false) do
      nil -> Operations.reject("not_found", "Fleet not found")
      row -> [row]
    end
  end

  defp fleet_digest(loadout, context) do
    seats = loadout.configuration["seats"] || []
    agent_ids = seats |> Enum.map(& &1["agent_id"]) |> Enum.uniq() |> Enum.sort()

    repos =
      agent_ids
      |> Enum.flat_map(fn agent_id ->
        case SeatScope.get(agent_id) do
          nil -> []
          scope -> scope.allowed_repos
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    activation = Ash.get!(Activation, loadout.id, not_found_error?: false)
    mode = if activation, do: activation.mode, else: "inactive"
    requested = if activation, do: activation.requested_seats, else: 0
    maximum = if activation, do: activation.max_seats, else: 0

    fleet = %{
      id: loadout.id,
      mode: mode,
      seats: seats,
      agent_ids: agent_ids,
      repos: repos,
      requested_seats: requested,
      max_seats: maximum
    }

    %{
      "fleet_id" => loadout.id,
      "mode" => mode,
      "refill_enabled" => FleetRefill.enabled?(),
      "repositories" => repos
    }
    |> Map.merge(seats_section(fleet, context))
    |> Map.merge(backlog_section(fleet, context))
    |> Map.merge(refill_section(fleet, context))
    |> Map.merge(launch_intents_section(fleet))
    |> Map.merge(obligations_section(fleet, context))
    |> Map.merge(intake_section(fleet, context))
  end

  # Section 1: Live seats for the fleet.
  defp seats_section(
         %{
           seats: configured_seats,
           agent_ids: agent_ids,
           requested_seats: requested,
           max_seats: maximum
         },
         %{
           now: now,
           stale_after: stale_after
         }
       ) do
    agents_by_id =
      if agent_ids == [] do
        %{}
      else
        Agent
        |> Ash.Query.filter(id in ^agent_ids)
        |> Ash.read!()
        |> Map.new(&{&1.id, &1})
      end

    cutoff = DateTime.add(now, -round(stale_after * 1_000_000), :microsecond)

    waiting_ids =
      if agent_ids == [] do
        MapSet.new()
      else
        %{rows: rows} =
          Repo.statement!(
            "SELECT DISTINCT requester_id FROM decision_requests WHERE requester_id = ANY($1) AND status IN ('open','answered')",
            [agent_ids]
          )

        MapSet.new(rows, &hd/1)
      end

    items =
      Enum.map(configured_seats, fn spec ->
        agent_id = spec["agent_id"]
        agent = agents_by_id[agent_id]

        live? =
          not is_nil(agent) and agent.kind == "seat" and is_nil(agent.retired_at) and
            not is_nil(agent.last_heartbeat) and
            DateTime.compare(agent.last_heartbeat, cutoff) != :lt

        availability =
          if agent, do: Availability.effective(agent)["state"], else: "unregistered"

        waiting? = MapSet.member?(waiting_ids, agent_id)
        status = if agent, do: agent.reported_status, else: nil

        %{
          "seat_id" => spec["seat_id"],
          "agent_id" => agent_id,
          "harness" => spec["harness"],
          "desired_host_id" => spec["desired_host_id"],
          "desired_model" => spec["desired_model"],
          "live" => live?,
          "reported_status" => status,
          "current_task_id" => agent && agent.current_task_id,
          "availability_state" => availability,
          "waiting_on_captain" => waiting?,
          "last_heartbeat" =>
            agent && agent.last_heartbeat && DateTime.to_iso8601(agent.last_heartbeat)
        }
      end)

    live_items = Enum.filter(items, & &1["live"])

    idle_count =
      Enum.count(
        live_items,
        &(&1["reported_status"] == "idle" and &1["availability_state"] == "active" and
            not &1["waiting_on_captain"])
      )

    busy_count = Enum.count(live_items, &(&1["reported_status"] == "busy"))

    %{
      "live_seats" => length(live_items),
      "requested_seats" => requested,
      "max_seats" => maximum,
      "seats" => %{
        "configured" => length(items),
        "requested" => requested,
        "maximum" => maximum,
        "live" => length(live_items),
        "idle" => idle_count,
        "busy" => busy_count,
        "stale" => length(items) - length(live_items),
        "items" => items
      }
    }
  end

  # Section 2: Open unassigned backlog depth by priority.
  defp backlog_section(%{repos: []}, _context) do
    %{
      "backlog" => %{
        "total" => 0,
        "by_priority" => %{},
        "priorities" => []
      }
    }
  end

  defp backlog_section(%{repos: repos}, _context) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT t.priority, count(*)::bigint
        FROM tasks t
        WHERE t.status = 'open'
          AND t.assignee_id IS NULL
          AND lower(t.repo) = ANY($1)
          AND NOT EXISTS (
            SELECT 1 FROM task_archives x WHERE x.id = t.id AND x.archived_at IS NOT NULL
          )
        GROUP BY t.priority
        ORDER BY t.priority ASC
        LIMIT 50
        """,
        [repos]
      )

    priorities =
      Enum.map(rows, fn [priority, count] ->
        %{"priority" => priority, "count" => count}
      end)

    by_priority =
      Map.new(rows, fn [priority, count] ->
        {Integer.to_string(priority), count}
      end)

    total = Enum.reduce(rows, 0, fn [_priority, count], acc -> acc + count end)

    %{
      "backlog" => %{
        "total" => total,
        "by_priority" => by_priority,
        "priorities" => priorities
      }
    }
  end

  # Section 3: Refill pending/overdue assignments, per-seat misses and dry-run pairs.
  defp refill_section(%{id: fleet_id}, %{now: now}) do
    pass = Ash.get!(Pass, fleet_id, not_found_error?: false)

    pending_rows =
      Assignment
      |> Ash.Query.filter(fleet_id == ^fleet_id and state == "assigned")
      |> Ash.Query.sort(deadline_at: :asc, id: :asc)
      |> Ash.Query.limit(@item_limit)
      |> Ash.read!()

    pending =
      Enum.map(pending_rows, fn row ->
        overdue? = DateTime.compare(row.deadline_at, now) != :gt

        %{
          "task_id" => row.task_id,
          "agent_id" => row.agent_id,
          "task_revision" => row.task_revision,
          "deadline_at" => DateTime.to_iso8601(row.deadline_at),
          "created_at" => DateTime.to_iso8601(row.created_at),
          "overdue" => overdue?,
          "overdue_seconds" =>
            if(overdue?, do: max(0, DateTime.diff(now, row.deadline_at)), else: 0)
        }
      end)

    overdue = Enum.filter(pending, & &1["overdue"])

    %{rows: miss_rows} =
      Repo.statement!(
        """
        SELECT agent_id, count(*)::bigint, max(resolved_at)
        FROM fleet_refill_assignments
        WHERE fleet_id = $1 AND state = 'missed'
        GROUP BY agent_id
        ORDER BY count(*) DESC, agent_id ASC
        LIMIT $2
        """,
        [fleet_id, @item_limit]
      )

    misses =
      Enum.map(miss_rows, fn [agent_id, count, last_missed_at] ->
        %{
          "agent_id" => agent_id,
          "count" => count,
          "last_missed_at" => last_missed_at && DateTime.to_iso8601(last_missed_at),
          "attention" => count >= 2
        }
      end)

    last_pass =
      pass &&
        %{
          "mode" => pass.mode,
          "pairs" => pass.pairs,
          "returned" => pass.returned,
          "passed_at" => DateTime.to_iso8601(pass.passed_at)
        }

    dry_run_pairs =
      if pass && pass.mode == "dry_run", do: pass.pairs, else: []

    %{
      "overdue_assignments" => overdue,
      "pending_assignments" => pending,
      "misses" => misses,
      "dry_run_pairs" => dry_run_pairs,
      "last_pass" => last_pass
    }
  end

  # Section 4: Open CI repair obligations for the fleet's repositories or seats.
  defp obligations_section(%{repos: [], agent_ids: []}, _context),
    do: %{"ci_obligations" => []}

  defp obligations_section(%{repos: repos, agent_ids: agent_ids}, %{now: now}) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT
          o.id::text,
          o.pull_request_id,
          pr.url,
          lower(pr.owner || '/' || pr.repo) AS repository,
          o.episode,
          o.repair_task_id,
          o.responsible_id,
          o.state,
          o.head_sha,
          o.blocker,
          o.reminders,
          o.last_progress_at,
          o.next_reminder_at,
          o.escalated_at,
          o.created_at
        FROM delivery_obligations o
        JOIN delivery_pull_requests pr ON pr.id = o.pull_request_id
        WHERE o.resolved_at IS NULL
          AND (
            lower(pr.owner || '/' || pr.repo) = ANY($1)
            OR o.responsible_id = ANY($2)
          )
        ORDER BY o.created_at ASC, o.id ASC
        LIMIT $3
        """,
        [repos, agent_ids, @item_limit]
      )

    obligations =
      Enum.map(rows, fn [
                          id,
                          pr_id,
                          pr_url,
                          repo,
                          episode,
                          repair_task_id,
                          responsible_id,
                          state,
                          head_sha,
                          blocker,
                          reminders,
                          last_progress_at,
                          next_reminder_at,
                          escalated_at,
                          created_at
                        ] ->
        %{
          "id" => id,
          "pull_request_id" => pr_id,
          "pr_url" => pr_url,
          "repository" => repo,
          "episode" => episode,
          "repair_task_id" => repair_task_id,
          "responsible_id" => responsible_id,
          "state" => state,
          "head_sha" => head_sha,
          "blocker" => blocker,
          "reminders" => reminders,
          "last_progress_at" => DateTime.to_iso8601(last_progress_at),
          "next_reminder_at" => DateTime.to_iso8601(next_reminder_at),
          "escalated_at" => escalated_at && DateTime.to_iso8601(escalated_at),
          "created_at" => DateTime.to_iso8601(created_at),
          "age_seconds" => max(0, DateTime.diff(now, created_at)),
          "overdue" => DateTime.compare(next_reminder_at, now) != :gt
        }
      end)

    %{"ci_obligations" => obligations}
  end

  # Launch intents by state, including dry-run would-launch intents.
  defp launch_intents_section(%{id: fleet_id}) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT id, seat_id, agent_id, harness, host_id, loadout_revision, state, reason,
               workspace_id, tab_id, pane_id, created_at, updated_at, reserved_at,
               launched_at, closed_at
        FROM (
          SELECT id, seat_id, agent_id, harness, host_id, loadout_revision, state, reason,
                 workspace_id, tab_id, pane_id, created_at, updated_at, reserved_at,
                 launched_at, closed_at,
                 row_number() OVER (PARTITION BY state ORDER BY updated_at DESC, id ASC) AS n
          FROM fleet_launch_intents
          WHERE fleet_id = $1
        ) ranked
        WHERE n <= $2
        ORDER BY state ASC, updated_at DESC, id ASC
        """,
        [fleet_id, @item_limit]
      )

    grouped = Enum.group_by(rows, fn row -> Enum.at(row, 6) end, &intent_item/1)

    %{
      "launch_intents" => Map.new(@intent_states, &{&1, Map.get(grouped, &1, [])})
    }
  end

  defp intent_item(row) do
    Map.new(Enum.zip(@intent_columns, row), fn
      {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
      pair -> pair
    end)
  end

  # Section 5: Recent intake results for the fleet's repositories (no bodies).
  defp intake_section(%{repos: []}, _context),
    do: %{"recent_intake" => []}

  defp intake_section(%{repos: repos}, _context),
    do: %{"recent_intake" => recent_intake_items(repos)}

  defp recent_intake_items(repos) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT
          i.id::text,
          i.request_id::text,
          r.request_key,
          r.filer_id,
          i.task_id,
          t.status,
          i.repository,
          i.issue,
          i.issue_state,
          i.issue_url,
          i.issue_number,
          i.reason,
          i.last_error,
          i.created_at,
          i.updated_at
        FROM intake_items i
        JOIN intake_requests r ON r.id = i.request_id
        LEFT JOIN tasks t ON t.id = i.task_id
        WHERE i.repository = ANY($1)
        ORDER BY i.created_at DESC, i.id DESC
        LIMIT $2
        """,
        [repos, @intake_limit]
      )

    Enum.map(rows, fn [
                        item_id,
                        request_id,
                        request_key,
                        filer_id,
                        task_id,
                        task_status,
                        repository,
                        issue,
                        issue_state,
                        issue_url,
                        issue_number,
                        reason,
                        last_error,
                        created_at,
                        updated_at
                      ] ->
      %{
        "item_id" => item_id,
        "request_id" => request_id,
        "request_key" => request_key,
        "filer_id" => filer_id,
        "task_id" => task_id,
        "task_status" => task_status,
        "repository" => repository,
        "issue" => issue,
        "issue_state" => issue_state,
        "issue_url" => issue_url,
        "issue_number" => issue_number,
        "reason" => reason,
        "last_error" => last_error,
        "created_at" => DateTime.to_iso8601(created_at),
        "updated_at" => DateTime.to_iso8601(updated_at)
      }
    end)
  end
end
