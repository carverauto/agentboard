defmodule Agentboard.SeatSupply do
  @moduledoc """
  Server-owned seat supply for captain-activated fleets (schema 47).

  A minute schedule compares each activated fleet's wanted seats with its live
  seats and writes at most one outstanding launch intent per missing loadout
  seat, bound to that seat's desired host and fenced by loadout revision. The
  server never chooses a binary, path or argv: an enrolled host daemon
  (`agentboard host fleet serve`) reserves live intents for its own host and
  reports each one launched, uncertain or failed. Default off behind
  `AGENTBOARD_SEAT_SUPPLY_ENABLED`; each fleet also needs a captain activation
  with `requested_seats` and `max_seats` above 0.
  """
  alias Agentboard.{Captain, FleetRefill, Repo}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Reads
  alias Agentboard.FleetLoadout.{Activation, Configuration}
  alias Agentboard.SeatSupply.{Host, Intent}
  require Ash.Query

  @system %{
    "agent" => "seat-supply",
    "model" => "system",
    "harness" => "ash",
    :seat_supply => true
  }
  @captain %{
    "agent" => "captain",
    "model" => "human",
    "harness" => "captain",
    :fleet_admin => true,
    :seat_supply => true
  }

  # A pending intent no host reserves in this long expires and frees its seat.
  @pending_ttl 600
  # After a failed launch the seat waits this long before a successor intent.
  @failure_cooldown 900
  # Host list bound. In-progress intents come first so a full page cannot hide
  # a reserved or pending seat behind older launched ones.
  @host_page 200
  # These states occupy their seat; the partial unique index allows one.
  @occupying ~w(pending reserved uncertain launched)
  # A host launch is in progress, and counts toward the host cap, in these.
  @in_progress ~w(reserved uncertain)
  @slug ~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/

  def enabled?, do: Application.get_env(:agentboard, :seat_supply_enabled, false) == true

  ## Supply pass

  def run_all do
    if enabled?() do
      fleets =
        Activation
        |> Ash.Query.filter(mode in ["dry_run", "live"])
        |> Ash.Query.sort(fleet_id: :asc)
        |> Ash.read!()

      passes =
        Map.new(fleets, fn row ->
          case Ops.transaction(fn -> supply(row.fleet_id) end) do
            {:ok, pass} -> {row.fleet_id, pass}
            {:error, code, _message} -> {row.fleet_id, %{"error" => code}}
          end
        end)

      {:ok, %{"enabled" => true, "fleets" => passes}}
    else
      {:ok, %{"enabled" => false}}
    end
  end

  # One transaction per fleet. The activation row lock serializes this pass
  # with captain activation changes; intent row locks serialize it with host
  # reservations and reports.
  defp supply(id) do
    Repo.statement!("SELECT fleet_id FROM fleet_activations WHERE fleet_id=$1 FOR UPDATE", [id])

    Repo.statement!(
      "SELECT id FROM fleet_launch_intents WHERE fleet_id=$1 AND closed_at IS NULL ORDER BY id FOR UPDATE",
      [id]
    )

    activation = Ash.get!(Activation, id, not_found_error?: false)
    loadout = Ash.get!(Configuration, id, not_found_error?: false)

    if activation && activation.mode in ~w(dry_run live) && loadout do
      stamp = Ops.now()
      open = Enum.reject(open_intents(id), &retire_stale(&1, activation, loadout, stamp))
      demand = demand(activation, loadout, open)
      pass = view(demand) |> Map.put("mode", activation.mode)

      if activation.mode == "live" do
        written = Enum.map(demand.launch, &write!(activation, loadout, &1, "pending", stamp))
        Map.put(pass, "written", Enum.map(written, & &1.seat_id))
      else
        Map.put(pass, "would_launch", record_dry_run(activation, loadout, open, demand, stamp))
      end
    else
      %{"skipped" => true}
    end
  end

  # Dry run keeps one dry_run intent per would-launch seat and supersedes the
  # rest. Dry-run intents never occupy a seat and no host ever sees them.
  defp record_dry_run(activation, loadout, open, demand, stamp) do
    would = MapSet.new(demand.launch, & &1["seat_id"])
    recorded = open |> Enum.filter(&(&1.state == "dry_run")) |> MapSet.new(& &1.seat_id)

    open
    |> Enum.filter(&(&1.state == "dry_run" and not MapSet.member?(would, &1.seat_id)))
    |> Enum.each(&close!(&1, "superseded", "No longer a would-launch seat", stamp, @system))

    demand.launch
    |> Enum.reject(&MapSet.member?(recorded, &1["seat_id"]))
    |> Enum.each(&write!(activation, loadout, &1, "dry_run", stamp))

    would |> MapSet.to_list() |> Enum.sort()
  end

  # Pending and dry-run intents are fenced by loadout revision and mode, and a
  # pending one also expires. A launched intent closes once its identity is no
  # longer live. Reserved and uncertain intents always keep their seat here.
  defp retire_stale(%{state: state} = intent, activation, loadout, stamp)
       when state in ~w(pending dry_run) do
    cond do
      intent.loadout_revision != loadout.revision or
          state == "pending" != (activation.mode == "live") ->
        close!(intent, "superseded", "Fleet loadout or activation mode changed", stamp, @system)

      state == "pending" and DateTime.diff(stamp, intent.created_at) >= @pending_ttl ->
        close!(intent, "expired", "No host reserved it within #{@pending_ttl}s", stamp, @system)

      true ->
        false
    end
  end

  defp retire_stale(%{state: "launched"} = intent, _activation, _loadout, stamp) do
    if gone?(intent),
      do: close!(intent, "closed", "Seat identity is no longer live", stamp, @system),
      else: false
  end

  defp retire_stale(_intent, _activation, _loadout, _stamp), do: false

  # Retired, or seen alive after launch and stale since. A seat that has not
  # registered yet is not gone: its pane may still be starting.
  defp gone?(intent) do
    {:ok, stale_after} = Reads.roster_threshold()

    %{rows: [[gone]]} =
      Repo.statement!(
        """
        SELECT coalesce((SELECT retired_at IS NOT NULL OR coalesce(last_heartbeat > $2
          AND last_heartbeat < clock_timestamp()-($3::float8*interval '1 second'), false)
          FROM agents WHERE id=$1), false)
        """,
        [intent.agent_id, intent.launched_at, stale_after]
      )

    gone
  end

  # wanted = min(requested, max, live + eligible backlog). A seat is live when
  # its identity is live or an outstanding intent occupies it. Launch
  # candidates are the remaining nonretired seats, in seat order, that are not
  # cooling down after a failed launch.
  defp demand(activation, loadout, open) do
    seats = loadout.configuration["seats"]
    agents = seats |> Enum.map(& &1["agent_id"]) |> Enum.sort()
    {:ok, stale_after} = Reads.roster_threshold()

    %{rows: rows} =
      Repo.statement!(
        "SELECT id, retired_at IS NOT NULL, coalesce(last_heartbeat >= clock_timestamp()-($2::float8*interval '1 second'), false) FROM agents WHERE id = ANY($1)",
        [agents, stale_after]
      )

    agent = Map.new(rows, fn [id, retired, live] -> {id, %{retired: retired, live: live}} end)
    occupied = open |> Enum.filter(&(&1.state in @occupying)) |> MapSet.new(& &1.seat_id)

    live =
      seats
      |> Enum.filter(&(MapSet.member?(occupied, &1["seat_id"]) or agent[&1["agent_id"]][:live]))
      |> MapSet.new(& &1["seat_id"])

    backlog = agents |> FleetRefill.repos() |> FleetRefill.backlog() |> length()

    wanted =
      Enum.min([activation.requested_seats, activation.max_seats, MapSet.size(live) + backlog])

    cooling = cooling(activation.fleet_id)

    launch =
      seats
      |> Enum.reject(
        &(MapSet.member?(live, &1["seat_id"]) or MapSet.member?(cooling, &1["seat_id"]) or
            agent[&1["agent_id"]][:retired] != false)
      )
      |> Enum.take(max(wanted - MapSet.size(live), 0))

    %{live: MapSet.size(live), backlog: backlog, wanted: wanted, launch: launch}
  end

  defp view(demand),
    do: %{
      "live_seats" => demand.live,
      "eligible_backlog" => demand.backlog,
      "wanted_seats" => demand.wanted
    }

  defp cooling(fleet_id) do
    %{rows: rows} =
      Repo.statement!(
        "SELECT DISTINCT seat_id FROM fleet_launch_intents WHERE fleet_id=$1 AND state='failed' AND closed_at > clock_timestamp()-($2::float8*interval '1 second')",
        [fleet_id, @failure_cooldown]
      )

    MapSet.new(rows, &hd/1)
  end

  defp open_intents(fleet_id),
    do:
      Intent
      |> Ash.Query.filter(fleet_id == ^fleet_id and is_nil(closed_at))
      |> Ash.Query.sort(seat_id: :asc)
      |> Ash.read!()

  defp write!(activation, loadout, seat, state, stamp),
    do:
      Ops.create(
        Intent,
        :record,
        %{
          id: Ecto.UUID.generate(),
          fleet_id: activation.fleet_id,
          seat_id: seat["seat_id"],
          agent_id: seat["agent_id"],
          harness: seat["harness"],
          host_id: seat["desired_host_id"],
          loadout_revision: loadout.revision,
          state: state,
          created_at: stamp,
          updated_at: stamp
        },
        @system
      )

  defp close!(intent, state, reason, stamp, actor) do
    Ops.update(
      intent,
      :transition,
      %{state: state, reason: reason, closed_at: stamp, updated_at: stamp},
      actor
    )

    true
  end

  ## Host daemon

  # In-progress intents, then pending, then launched, oldest first within each
  # group, up to @host_page. Dry-run intents are never listed. intents_complete
  # is false when the page is full, so a missing id is not proof the intent closed.
  def host_intents(host_id, token) do
    with {:ok, host} <- host(host_id, token) do
      Ops.transaction(fn ->
        intents = host_intent_page(host_id)
        modes = fleet_modes(intents)

        %{
          "host" => host_view(host),
          "seat_supply_enabled" => enabled?(),
          "intents_complete" => length(intents) < @host_page,
          "intents" => Enum.map(intents, &host_intent_view(&1, modes))
        }
      end)
    end
  end

  defp host_intent_page(host_id) do
    in_progress = host_intent_states(host_id, ~w(reserved uncertain), @host_page)
    pending = host_intent_states(host_id, ~w(pending), @host_page - length(in_progress))

    launched =
      host_intent_states(host_id, ~w(launched), @host_page - length(in_progress) - length(pending))

    in_progress ++ pending ++ launched
  end

  defp host_intent_states(_host_id, _states, limit) when limit <= 0, do: []

  defp host_intent_states(host_id, states, limit) do
    Intent
    |> Ash.Query.filter(host_id == ^host_id and state in ^states)
    |> Ash.Query.sort(created_at: :asc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
  end

  defp fleet_modes([]), do: %{}

  defp fleet_modes(intents) do
    ids = intents |> Enum.map(& &1.fleet_id) |> Enum.uniq()

    Activation
    |> Ash.Query.filter(fleet_id in ^ids)
    |> Ash.read!()
    |> Map.new(&{&1.fleet_id, &1.mode})
  end

  defp host_intent_view(intent, modes) do
    Map.put(intent_view(intent), "fleet_mode", Map.get(modes, intent.fleet_id, "inactive"))
  end

  def reserve(host_id, token, id) do
    with {:ok, _} <- host(host_id, token), :ok <- intent_id(id) do
      host_transaction(id, host_id, fn intent ->
        cond do
          intent.state == "reserved" ->
            intent

          intent.state != "pending" ->
            {:refused, "conflict", "Launch intent is #{intent.state}, not pending"}

          not enabled?() ->
            {:refused, "conflict", "Seat supply is disabled"}

          true ->
            reserve_pending(intent, host_id)
        end
      end)
    end
  end

  defp reserve_pending(intent, host_id) do
    stamp = Ops.now()
    activation = Ash.get!(Activation, intent.fleet_id, not_found_error?: false)
    loadout = Ash.get!(Configuration, intent.fleet_id, not_found_error?: false)

    seat =
      loadout && Enum.find(loadout.configuration["seats"], &(&1["seat_id"] == intent.seat_id))

    cond do
      is_nil(activation) or activation.mode != "live" or is_nil(seat) or
        loadout.revision != intent.loadout_revision or seat["agent_id"] != intent.agent_id or
        seat["harness"] != intent.harness or seat["desired_host_id"] != host_id ->
        close!(intent, "superseded", "Fleet loadout or activation changed", stamp, @system)
        {:refused, "conflict", "Launch intent was superseded"}

      DateTime.diff(stamp, intent.created_at) >= @pending_ttl ->
        close!(intent, "expired", "No host reserved it within #{@pending_ttl}s", stamp, @system)
        {:refused, "conflict", "Launch intent expired"}

      true ->
        # The host row lock serializes reservations against this host's cap.
        Repo.statement!("SELECT host_id FROM fleet_hosts WHERE host_id=$1 FOR UPDATE", [host_id])
        cap = Ash.get!(Host, host_id).launch_cap

        %{rows: [[busy]]} =
          Repo.statement!(
            "SELECT count(*) FROM fleet_launch_intents WHERE host_id=$1 AND state = ANY($2)",
            [host_id, @in_progress]
          )

        if busy >= cap,
          do: {:refused, "conflict", "Host launch cap #{cap} is reached"},
          else:
            Ops.update(
              intent,
              :transition,
              %{state: "reserved", reserved_at: stamp, updated_at: stamp},
              host_actor(host_id)
            )
    end
  end

  # reserved -> launched | uncertain | failed; uncertain -> launched;
  # launched -> closed when the host sees the pane gone. A repeated report of
  # the current state with the same identity replays.
  def report(host_id, token, id, data) do
    with {:ok, _} <- host(host_id, token),
         :ok <- intent_id(id),
         {:ok, report} <- validate_report(data) do
      host_transaction(id, host_id, fn intent ->
        allowed =
          case intent.state do
            "reserved" -> ~w(launched uncertain failed)
            "uncertain" -> ~w(launched uncertain)
            "launched" -> ~w(closed)
            _ -> []
          end

        cond do
          intent.state == report.state and same_report?(intent, report) ->
            intent

          report.state not in allowed ->
            {:refused, "conflict",
             "Launch intent is #{intent.state}; cannot report #{report.state}"}

          true ->
            stamp = Ops.now()

            attrs =
              report
              |> identity()
              |> Map.merge(%{state: report.state, reason: report.reason, updated_at: stamp})
              |> Map.merge(stamps(report.state, stamp))

            Ops.update(intent, :transition, attrs, host_actor(host_id))
        end
      end)
    end
  end

  defp stamps("launched", stamp), do: %{launched_at: stamp}
  defp stamps(state, stamp) when state in ~w(failed closed), do: %{closed_at: stamp}
  defp stamps(_state, _stamp), do: %{}

  # Host identity fields a report carries; an omitted field keeps its value.
  defp identity(report),
    do:
      report
      |> Map.take([:workspace_id, :tab_id, :pane_id, :lease_path])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

  defp same_report?(intent, report),
    do:
      intent.reason == report.reason and
        Enum.all?(identity(report), fn {key, value} -> Map.get(intent, key) == value end)

  defp validate_report(data) when is_map(data) do
    fields = ~w(reason workspace_id tab_id pane_id lease_path)

    with true <- Enum.all?(Map.keys(data), &(&1 in ["state" | fields])),
         true <- data["state"] in ~w(launched uncertain failed closed),
         true <- Enum.all?(fields, &(is_nil(data[&1]) or text?(data[&1], 500))),
         true <- data["state"] != "launched" or text?(data["pane_id"], 500),
         true <- data["state"] not in ~w(uncertain failed closed) or text?(data["reason"], 500) do
      {:ok, Map.new(["state" | fields], fn key -> {String.to_existing_atom(key), data[key]} end)}
    else
      _ ->
        {:error, "invalid_input",
         "Report requires state launched (with pane_id), uncertain, failed or closed (with reason); optional workspace_id, tab_id, pane_id and lease_path; unknown fields are forbidden"}
    end
  end

  defp validate_report(_), do: validate_report(nil)

  defp host_transaction(id, host_id, fun) do
    Ops.transaction(fn ->
      Repo.statement!("SELECT id FROM fleet_launch_intents WHERE id=$1 FOR UPDATE", [id])

      case Ash.get!(Intent, id, not_found_error?: false) do
        %{host_id: ^host_id} = intent -> fun.(intent)
        _ -> {:refused, "not_found", "Launch intent not found"}
      end
    end)
    |> case do
      {:ok, {:refused, code, message}} -> {:error, code, message}
      {:ok, intent} -> {:ok, %{"intent" => intent_view(intent)}}
      error -> error
    end
  end

  defp host(host_id, token) do
    row =
      is_binary(host_id) and Regex.match?(@slug, host_id) and is_binary(token) and
        Ash.get!(Host, host_id, not_found_error?: false)

    if row && Plug.Crypto.secure_compare(digest(token), row.token_hash),
      do: {:ok, row},
      else: {:error, "unauthorized", "Enrolled fleet host token required"}
  end

  defp host_actor(host_id),
    do: %{
      "agent" => "fleet-host:" <> host_id,
      "model" => "system",
      "harness" => "fleet-host",
      :seat_supply => true
    }

  ## Captain

  def enroll_host(host_id, capability, data) do
    with :ok <- authority(capability),
         :ok <- slug(host_id, "Valid host ID required"),
         {:ok, cap, rotate} <- validate_host(data) do
      Ops.transaction(fn ->
        Repo.statement!("SELECT host_id FROM fleet_hosts WHERE host_id=$1 FOR UPDATE", [host_id])
        prior = Ash.get!(Host, host_id, not_found_error?: false)
        token = if is_nil(prior) or rotate, do: issue_token()
        stamp = Ops.now()

        cond do
          prior && is_nil(token) && prior.launch_cap == cap ->
            %{"host" => host_view(prior), "changed" => false}

          prior ->
            attrs = %{
              launch_cap: cap,
              revision: prior.revision + 1,
              changed_by: "captain",
              updated_at: stamp
            }

            attrs = if token, do: Map.put(attrs, :token_hash, digest(token)), else: attrs
            row = Ops.update(prior, :change, attrs, @captain)
            issued(%{"host" => host_view(row), "changed" => true}, token)

          true ->
            row =
              Ops.create(
                Host,
                :enroll,
                %{
                  host_id: host_id,
                  token_hash: digest(token),
                  launch_cap: cap,
                  revision: 1,
                  changed_by: "captain",
                  created_at: stamp,
                  updated_at: stamp
                },
                @captain
              )

            issued(%{"host" => host_view(row), "changed" => true}, token)
        end
      end)
    end
  end

  defp issued(response, nil), do: response
  defp issued(response, token), do: Map.put(response, "token", token)

  defp validate_host(data) when is_map(data) do
    cap = data["launch_cap"]
    rotate = Map.get(data, "rotate_token", false)

    if Enum.all?(Map.keys(data), &(&1 in ~w(launch_cap rotate_token))) and is_integer(cap) and
         cap in 0..32 and is_boolean(rotate),
       do: {:ok, cap, rotate},
       else:
         {:error, "invalid_input",
          "Host enrollment requires integer launch_cap from 0 to 32 and optional boolean rotate_token; unknown fields are forbidden"}
  end

  defp validate_host(_), do: validate_host(nil)

  def abandon(fleet_id, capability, id, data) do
    with :ok <- authority(capability),
         :ok <- slug(fleet_id, "Valid fleet ID required"),
         :ok <- intent_id(id),
         {:ok, reason} <- validate_abandon(data) do
      Ops.transaction(fn ->
        Repo.statement!("SELECT id FROM fleet_launch_intents WHERE id=$1 FOR UPDATE", [id])

        case Ash.get!(Intent, id, not_found_error?: false) do
          %{fleet_id: ^fleet_id, closed_at: nil} = intent ->
            stamp = Ops.now()

            row =
              Ops.update(
                intent,
                :transition,
                %{state: "abandoned", reason: reason, closed_at: stamp, updated_at: stamp},
                @captain
              )

            %{"intent" => intent_view(row)}

          %{fleet_id: ^fleet_id} = intent ->
            Ops.reject("conflict", "Launch intent is already #{intent.state}")

          _ ->
            Ops.reject("not_found", "Launch intent not found")
        end
      end)
    end
  end

  defp validate_abandon(%{"reason" => reason} = data) when map_size(data) == 1 do
    if text?(reason, 500),
      do: {:ok, String.trim(reason)},
      else: validate_abandon(nil)
  end

  defp validate_abandon(_),
    do: {:error, "invalid_input", "Abandon requires only a nonblank reason up to 500 bytes"}

  def status(fleet_id, capability) do
    with :ok <- authority(capability), :ok <- slug(fleet_id, "Valid fleet ID required") do
      Ops.transaction(fn ->
        activation = Ash.get!(Activation, fleet_id, not_found_error?: false)
        loadout = Ash.get!(Configuration, fleet_id, not_found_error?: false)
        open = open_intents(fleet_id)

        closed =
          Intent
          |> Ash.Query.filter(fleet_id == ^fleet_id and not is_nil(closed_at))
          |> Ash.Query.sort(closed_at: :desc, id: :asc)
          |> Ash.Query.limit(50)
          |> Ash.read!()

        hosts =
          case loadout do
            nil -> []
            row -> row.configuration["seats"] |> Enum.map(& &1["desired_host_id"]) |> Enum.uniq()
          end

        %{
          "supply" => %{
            "fleet_id" => fleet_id,
            "seat_supply_enabled" => enabled?(),
            "activation" => FleetRefill.activation(activation, fleet_id),
            "demand" =>
              if(activation && activation.mode in ~w(dry_run live) && loadout,
                do: view(demand(activation, loadout, open))
              ),
            "hosts" =>
              hosts
              |> Enum.sort()
              |> Enum.map(fn id ->
                case Ash.get!(Host, id, not_found_error?: false) do
                  nil -> %{"host_id" => id, "enrolled" => false}
                  row -> Map.put(host_view(row), "enrolled", true)
                end
              end),
            "open" => Enum.map(open, &intent_view/1),
            "recent" => Enum.map(closed, &intent_view/1)
          }
        }
      end)
    end
  end

  ## Shared

  defp intent_view(intent), do: Ops.public(intent)

  defp host_view(host),
    do: %{
      "host_id" => host.host_id,
      "launch_cap" => host.launch_cap,
      "revision" => host.revision,
      "changed_by" => host.changed_by,
      "updated_at" => DateTime.to_iso8601(host.updated_at)
    }

  defp issue_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= max and
        String.trim(value) != "" and not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, value)

  defp intent_id(id),
    do:
      if(is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id)),
        do: :ok,
        else: {:error, "invalid_input", "Valid launch intent ID required"}
      )

  defp slug(value, message),
    do:
      if(is_binary(value) and Regex.match?(@slug, value),
        do: :ok,
        else: {:error, "invalid_input", message}
      )

  defp authority(capability),
    do:
      if(Captain.authorized?(capability),
        do: :ok,
        else: {:error, "forbidden", "Verified captain capability required"}
      )
end
