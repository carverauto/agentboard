defmodule AgentboardWeb.BoardLive do
  use Phoenix.LiveView, layout: false
  alias Agentboard.Board
  @statuses ~w(open assigned in_progress blocked review done cancelled)
  @topics ~w(ab_agents ab_tasks ab_messages ab_quota)

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        data: %{},
        decisions: %{
          "decisions" => [],
          "answered" => [],
          "total" => nil,
          "answered_total" => 0,
          "next_cursor" => nil
        },
        decision_unavailable: false,
        workers: %{},
        review_ci: %{},
        ci_unavailable: false,
        health_unavailable: false,
        filters: %{},
        column_pages: %{},
        paging_view: nil,
        unavailable: false,
        last_read: nil,
        loaded: false,
        refresh_pending: false,
        quota_detail: nil,
        availability_form: nil,
        availability_error: nil,
        availability_return_focus: "availability-open",
        scope_form: nil,
        scope_error: nil,
        captain: session["captain"],
        archive_error: nil,
        statuses: @statuses
      )

    if connected?(socket) do
      Enum.each(@topics, &Phoenix.PubSub.subscribe(Agentboard.PubSub, &1))
      Process.send_after(self(), :fallback, 5000)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      Map.take(
        params,
        ~w(id status owner repo label to task unread provider account cursor message_cursor decision_cursor waiting availability kind retired)
      )

    changed =
      socket.assigns.filters != filters or
        socket.assigns.paging_view != socket.assigns.live_action

    socket =
      assign(socket,
        filters: filters,
        quota_detail: nil,
        availability_form: nil,
        availability_error: nil,
        scope_form: nil,
        scope_error: nil,
        paging_view: socket.assigns.live_action,
        column_pages: if(changed, do: %{}, else: socket.assigns.column_pages)
      )

    {:noreply, if(connected?(socket), do: reload(socket), else: socket)}
  end

  @impl true
  def handle_event("column_page", %{"status" => status, "direction" => direction}, socket)
      when direction in ~w(prev next) do
    with true <- socket.assigns.live_action in [:board, :archive],
         %{} = column <- get_in(socket.assigns.data, ["columns", status]),
         current = Map.get(socket.assigns.column_pages, status, initial_page()),
         %{} = page <- advance_page(current, column, direction) do
      candidate =
        socket
        |> assign(column_pages: Map.put(socket.assigns.column_pages, status, page))
        |> reload()

      # A failed read retains both the last cards and their matching cursor history.
      {:noreply,
       if(candidate.assigns.unavailable,
         do: assign(candidate, column_pages: socket.assigns.column_pages),
         else: candidate
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("column_page", _params, socket), do: {:noreply, socket}

  def handle_event("open_scope", %{"id" => id}, socket) do
    with true <- socket.assigns.live_action == :agents,
         true <- Agentboard.Captain.authorized?(socket.assigns.captain),
         %{} = agent <- Enum.find(socket.assigns.data["agents"] || [], &(&1["id"] == id)),
         %{"revision" => revision} = scope when is_integer(revision) <- agent["scope"] do
      form =
        Map.new(~w(allowed_repos required_labels allowed_labels), fn key ->
          {key, Enum.join(scope[key] || [], "\n")}
        end)
        |> Map.merge(%{"agent_id" => id, "revision" => revision})

      {:noreply, assign(socket, scope_form: form, scope_error: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_scope", _params, socket), do: {:noreply, socket}

  def handle_event("close_scope", _params, socket),
    do: {:noreply, assign(socket, scope_form: nil, scope_error: nil)}

  def handle_event("scope_draft", params, socket) do
    if scope_editable?(socket) do
      {:noreply, assign(socket, scope_form: scope_draft(socket.assigns.scope_form, params))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_scope", params, socket) do
    if scope_editable?(socket) do
      form = scope_draft(socket.assigns.scope_form, params)

      actor = %{
        "agent" => "captain",
        "model" => "human",
        "harness" => "captain",
        :availability_admin => true
      }

      result =
        with {:ok, data} <- scope_data(form, params),
             {:ok, _} <- Board.register(actor, %{"name" => "Captain"}) do
          Agentboard.SeatScope.set(form["agent_id"], actor, data)
        end

      case result do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(scope_form: nil, scope_error: nil)
           |> put_flash(:info, "Seat scope updated.")
           |> reload()}

        {:error, code, message} ->
          # Refresh the displayed baseline without replacing the unsaved draft.
          # Closing and reopening can then review the competing committed edit.
          socket = if code == "conflict", do: reload(socket), else: socket

          message =
            if code == "conflict",
              do:
                "Seat scope changed since you opened this editor. Your draft is kept. Close and reopen to review the latest scope before saving again.",
              else: message

          {:noreply, assign(socket, scope_form: form, scope_error: message)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_availability", params, socket) do
    id = params["id"]

    with true <- socket.assigns.live_action == :agents,
         true <- Agentboard.Captain.authorized?(socket.assigns.captain),
         true <- is_nil(id) or Enum.any?(socket.assigns.data["agents"] || [], &(&1["id"] == id)) do
      {:noreply,
       assign(socket,
         availability_form: availability_draft(%{"agent_id" => id}),
         availability_error: nil,
         availability_return_focus:
           if(is_nil(id), do: "availability-open", else: "availability-open-#{id}")
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_availability", _params, socket),
    do: {:noreply, assign(socket, availability_form: nil, availability_error: nil)}

  def handle_event("availability_draft", params, socket) do
    if Agentboard.Captain.authorized?(socket.assigns.captain) and socket.assigns.availability_form do
      {:noreply, assign(socket, availability_form: availability_draft(params))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_availability", params, socket) do
    if Agentboard.Captain.authorized?(socket.assigns.captain) do
      actor = %{
        "agent" => "captain",
        "model" => "human",
        "harness" => "captain",
        :availability_admin => true
      }

      # The captain UI uses a fixed registered identity; form input never sets role.
      with {:ok, _} <- Board.register(actor, %{"name" => "Captain"}),
           data =
             params
             |> Map.take(~w(agent_id harness model_pattern state reason until))
             |> Enum.reject(fn {_k, v} -> v == "" end)
             |> Map.new(),
           {:ok, _} <- Agentboard.Availability.set(actor, data) do
        {:noreply,
         socket
         |> assign(archive_error: nil, availability_form: nil, availability_error: nil)
         |> put_flash(:info, "Availability updated.")
         |> reload()}
      else
        {:error, _, message} ->
          {:noreply,
           assign(socket,
             availability_form: availability_draft(params),
             availability_error: message
           )}
      end
    else
      {:noreply, assign(socket, archive_error: "Unlock captain controls in Settings first")}
    end
  end

  def handle_event("decision_promote", params, socket) do
    if Agentboard.Captain.authorized?(socket.assigns.captain) do
      actor = %{
        "agent" => "captain",
        "model" => "human",
        "harness" => "captain",
        :decision_admin => true
      }

      kind =
        if(is_binary(params["kind"]) and params["kind"] != "",
          do: params["kind"],
          else: "approval"
        )

      options =
        case params["options"] do
          nil ->
            []

          values when is_list(values) ->
            values |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == ""))

          value when is_binary(value) ->
            value
            |> String.split(~r/\r?\n/)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          _ ->
            []
        end

      data =
        Map.take(params, ~w(task source_type source_id question))
        |> Map.merge(%{"kind" => kind, "options" => options})

      result =
        with {revision, ""} <- Integer.parse(params["revision"] || ""),
             {:ok, _} <- Board.register(actor, %{"name" => "Captain"}) do
          Agentboard.Decisions.promote(actor, Map.put(data, "revision", revision))
        else
          {:error, _, _} = error -> error
          _ -> {:error, "invalid_input", "Current task revision required"}
        end

      case result do
        {:ok, _} -> {:noreply, socket |> assign(archive_error: nil) |> reload()}
        {:error, _, message} -> {:noreply, assign(socket, archive_error: message)}
      end
    else
      {:noreply, assign(socket, archive_error: "Unlock captain controls before promotion")}
    end
  end

  def handle_event(event, params, socket) when event in ~w(decision_answer decision_supersede) do
    if Agentboard.Captain.authorized?(socket.assigns.captain) do
      actor = %{
        "agent" => "captain",
        "model" => "human",
        "harness" => "captain",
        :decision_admin => true
      }

      action = if event == "decision_answer", do: "answer", else: "supersede"
      data = Map.take(params, if(action == "answer", do: ["answer"], else: ["reason"]))

      with {:ok, _} <- Board.register(actor, %{"name" => "Captain"}),
           {:ok, _} <- Agentboard.Decisions.mutate(params["decision_id"], action, actor, data) do
        {:noreply, socket |> assign(archive_error: nil) |> reload()}
      else
        {:error, _, message} -> {:noreply, assign(socket, archive_error: message)}
      end
    else
      {:noreply, assign(socket, archive_error: "Unlock captain controls in Settings first")}
    end
  end

  def handle_event("open_quota", %{"id" => id}, %{assigns: %{live_action: :quota}} = socket) do
    observation = Enum.find(socket.assigns.data["quota"] || [], &(to_string(&1["id"]) == id))
    {:noreply, assign(socket, quota_detail: observation)}
  end

  def handle_event("close_quota", _, socket), do: {:noreply, assign(socket, quota_detail: nil)}

  def handle_event("archive_task", params, socket) do
    with true <- Agentboard.Captain.authorized?(socket.assigns.captain),
         true <- params["archived"] in ~w(true false),
         {revision, ""} <- Integer.parse(params["revision"] || ""),
         {:ok, _} <-
           Agentboard.Housekeeping.change(
             params["id"],
             params["archived"] == "true",
             revision,
             Agentboard.Captain.actor()
           ) do
      {:noreply, socket |> assign(archive_error: nil) |> reload()}
    else
      {:error, _, message} ->
        {:noreply, assign(socket, archive_error: message)}

      _ ->
        {:noreply,
         assign(socket, archive_error: "Unlock captain controls in Settings before archiving")}
    end
  end

  defp availability_draft(params) do
    defaults =
      Map.new(~w(agent_id harness model_pattern reason until), &{&1, ""})
      |> Map.put("state", "active")

    values =
      params
      |> Map.take(~w(agent_id harness model_pattern state reason until))
      |> Enum.filter(fn {_key, value} -> is_binary(value) end)
      |> Map.new()

    Map.merge(defaults, values)
  end

  defp scope_editable?(socket),
    do:
      socket.assigns.live_action == :agents and
        Agentboard.Captain.authorized?(socket.assigns.captain) and
        is_map(socket.assigns.scope_form)

  defp scope_draft(form, params) do
    values =
      params
      |> Map.take(~w(allowed_repos required_labels allowed_labels))
      |> Enum.filter(fn {_key, value} -> is_binary(value) end)
      |> Map.new()

    # The rendered agent and revision stay server-owned across forged events,
    # draft changes and roster refreshes. Conflicts never advance this revision.
    Map.merge(form, values)
  end

  defp scope_data(form, params) do
    fields = ~w(allowed_repos required_labels allowed_labels)

    if Enum.all?(fields, &is_binary(params[&1])) do
      data =
        Map.new(fields, fn key ->
          {key, form[key] |> String.split(~r/\r?\n/) |> Enum.reject(&(&1 == ""))}
        end)
        |> Map.put("revision", form["revision"])

      with {:ok, _} <- Agentboard.SeatScope.validate(data), do: {:ok, data}
    else
      {:error, "invalid_input",
       "Supply every scope field as text; empty label fields disable their gate."}
    end
  end

  defp initial_page, do: %{cursor: nil, history: [], number: 1}

  defp advance_page(page, %{"next_cursor" => cursor}, "next") when is_binary(cursor),
    do: %{cursor: cursor, history: [page.cursor | page.history], number: page.number + 1}

  defp advance_page(%{history: [cursor | history], number: number}, _column, "prev"),
    do: %{cursor: cursor, history: history, number: number - 1}

  defp advance_page(_page, _column, _direction), do: nil

  @impl true
  def handle_info({:board_changed, _topic, _reason}, socket) do
    if socket.assigns.refresh_pending do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh, 50)
      {:noreply, assign(socket, refresh_pending: true)}
    end
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_pending: false) |> reload()}

  def handle_info(:fallback, socket) do
    Process.send_after(self(), :fallback, 5000)
    {:noreply, reload(socket)}
  end

  defp reload(socket) do
    case load(socket.assigns.live_action, socket.assigns.filters, socket.assigns.column_pages) do
      {:ok, data} ->
        health = load_health(data)
        ci = load_review_ci(data)
        decisions = load_decisions(socket.assigns.live_action, socket.assigns.filters)

        assign(socket,
          data: data,
          decisions:
            case decisions do
              {:ok, records} -> records
              _ -> socket.assigns.decisions
            end,
          decision_unavailable: not match?({:ok, _}, decisions),
          workers:
            case health do
              {:ok, workers} -> workers
              _ -> socket.assigns.workers
            end,
          health_unavailable: not match?({:ok, _}, health),
          review_ci:
            case ci do
              {:ok, states} -> states
              _ -> socket.assigns.review_ci
            end,
          ci_unavailable: not match?({:ok, _}, ci),
          loaded: true,
          unavailable: false,
          last_read: DateTime.utc_now()
        )

      {:error, _, _} ->
        assign(socket, unavailable: true, decision_unavailable: true)
    end
  end

  defp load_decisions(view, filters) when view in [:board, :task] do
    query =
      filters |> Map.take(~w(owner repo)) |> Map.put("waiting", "true") |> Map.put("limit", "20")

    query = if view == :task, do: Map.put(query, "task", filters["id"]), else: query

    Agentboard.Decisions.Waiting.page(
      put_cursor(Map.delete(query, "waiting"), filters["decision_cursor"])
    )
  end

  defp load_decisions(_, _), do: {:ok, %{"decisions" => [], "next_cursor" => nil}}

  defp load(view, filters, column_pages) when view in [:board, :archive] do
    selected =
      if view == :archive,
        do: ["done"],
        else: if(filters["status"] in @statuses, do: [filters["status"]], else: @statuses)

    with {:ok, roster} <- Board.snapshot("agents", %{}) do
      columns =
        Enum.reduce_while(selected, {:ok, %{}}, fn status, {:ok, columns} ->
          q =
            filters
            |> Map.take(~w(owner repo label))
            |> Map.merge(%{"status" => status, "limit" => "20"})
            |> Map.put("archive", if(view == :archive, do: "archived", else: "active"))

          state = Map.get(column_pages, status, initial_page())

          with {:ok, total} <- Board.count("tasks", q),
               {:ok, page} <- Board.page("tasks", put_cursor(q, state.cursor)) do
            page =
              Map.merge(page, %{
                "total" => total,
                "page" => state.number,
                "previous" => state.history != []
              })

            {:cont, {:ok, Map.put(columns, status, page)}}
          else
            error -> {:halt, error}
          end
        end)

      with {:ok, columns} <- columns,
           do:
             {:ok,
              %{"columns" => columns, "roster" => Map.new(roster["agents"], &{&1["id"], &1})}}
    end
  end

  defp load(view, filters, _column_pages), do: load(view, filters)

  defp load(:task, filters) do
    with {:ok, task} <-
           Board.show(
             "tasks",
             filters["id"],
             filters |> Map.take(~w(cursor)) |> Map.put("limit", "50")
           ),
         {:ok, messages} <-
           Board.page(
             "messages",
             %{"task" => filters["id"], "limit" => "50"} |> put_cursor(filters["message_cursor"])
           ),
         {:ok, agents} <- Board.snapshot("agents", %{}) do
      {:ok,
       Map.merge(task, %{
         "messages" => messages["messages"],
         "message_cursor" => messages["next_cursor"],
         "roster" => Map.new(agents["agents"], &{&1["id"], &1})
       })}
    end
  end

  defp load(:agents, filters) do
    with {:ok, data} <-
           Board.page(
             "agents",
             Map.take(filters, ~w(cursor waiting availability kind retired))
             |> Map.put("limit", "100")
           ),
         {:ok, seconds} <- Agentboard.Board.Reads.roster_threshold() do
      data = Map.put(data, "roster_stale_after", seconds)

      case Agentboard.Auth.report() do
        {:ok, report} ->
          {:ok, Map.put(data, "authentication", report)}

        {:error, _, _} ->
          {:ok,
           Map.put(data, "authentication", %{
             "status" => "unavailable",
             "mode" => Agentboard.Auth.mode()
           })}
      end
    end
  end

  defp load(:messages, filters),
    do:
      Board.page(
        "messages",
        Map.take(filters, ~w(to task unread cursor)) |> Map.put("limit", "100")
      )

  defp load(:quota, filters),
    do:
      Board.page(
        "quota",
        Map.take(filters, ~w(provider account cursor)) |> Map.put("limit", "50")
      )

  defp put_cursor(map, nil), do: map
  defp put_cursor(map, cursor), do: Map.put(map, "cursor", cursor)
  defp label(status), do: status |> String.replace("_", " ") |> String.capitalize()
  defp value(nil), do: "Unknown"
  defp value(value), do: value

  defp path(view) do
    case view do
      :board -> "/"
      :archive -> "/archive"
      :agents -> "/agents"
      :messages -> "/messages"
      :quota -> "/quota"
      _ -> "/"
    end
  end

  defp page_link(view, filters, cursor, key \\ "cursor") do
    base = if view == :task, do: "/tasks/" <> filters["id"], else: path(view)
    base <> "?" <> URI.encode_query(filters |> Map.delete("id") |> Map.put(key, cursor))
  end

  defp owner_stale?(task, roster), do: get_in(roster, [task["assignee_id"], "stale"]) == true

  defp stale_label(seconds) when is_number(seconds) do
    total = round(seconds)
    if rem(total, 60) == 0, do: "#{div(total, 60)}m", else: "#{total}s"
  end

  defp stale_label(_), do: "unknown"

  defp age(nil), do: "No heartbeat"

  defp age(stamp), do: AgentboardWeb.RelativeTime.age(stamp)

  defp remaining(window),
    do:
      if(is_number(window["percent_remaining"]),
        do: "#{window["percent_remaining"]}%",
        else: "Unknown"
      )

  defp trustworthy?(observation, scope) do
    observation["observation_stale"] != true and observation["state"]["stale"] != true and
      observation["state"]["status"] == "fresh" and
      scope["status"] == "known" and not Map.has_key?(scope, "bound_conflict") and
      Enum.all?(
        Map.get(scope, "bounded_by", []),
        &(&1 not in Map.get(observation["state"], "untrusted_window_ids", []))
      )
  end

  defp load_review_ci(data) do
    tasks = (data["columns"] || %{}) |> Map.values() |> Enum.flat_map(&(&1["tasks"] || []))
    tasks = tasks ++ if(data["task"], do: [data["task"]], else: [])
    urls = tasks |> Enum.map(& &1["pr_url"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    urls
    |> Enum.chunk_every(20)
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, accumulated} ->
      case Agentboard.Delivery.Reads.review(chunk) do
        {:ok, records} -> {:cont, {:ok, Map.merge(accumulated, records)}}
        error -> {:halt, error}
      end
    end)
  end

  attr(:state, :map, default: nil)
  attr(:unavailable, :boolean, default: false)

  def review_ci(assigns) do
    state =
      if assigns.unavailable,
        do: "unavailable",
        else: (assigns.state && assigns.state.ci_state) || "unknown"

    {symbol, title, tone} =
      case state do
        "passing" -> {"✓", "CI passing", "healthy"}
        "pending" -> {"◷", "CI pending", ""}
        "failing" -> {"×", "CI failing", "danger"}
        "stale" -> {"⌛", "CI stale", "warning"}
        "unavailable" -> {"?", "CI unavailable", "warning"}
        _ -> {"?", "CI unknown", ""}
      end

    assigns = assign(assigns, symbol: symbol, title: title, tone: tone)

    ~H"""
    <div class="review-ci"><span class={"flag " <> @tone}><span aria-hidden="true">{@symbol}</span> {@title}</span><span :if={@state && @state[:draft] == true && !@unavailable} class="flag"><span aria-hidden="true">◇</span> {if @state[:fresh], do: "Draft", else: "Draft (last observed)"}</span><time :if={@state && @state[:observed_at]} datetime={to_string(@state.observed_at)} title={to_string(@state.observed_at)}>{AgentboardWeb.RelativeTime.age(to_string(@state.observed_at))}</time></div>
    """
  end

  defp load_health(data) do
    ids = Enum.map(data["agents"] || [], & &1["id"]) ++ [get_in(data, ["task", "assignee_id"])]

    Agentboard.Board.Operations.transaction(fn ->
      ids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(&{&1, Agentboard.Delivery.Reads.health(&1)})
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="board-view">
      <aside :if={@health_unavailable} class="notice warning" role="alert">Worker delivery health is unavailable. Retained values are last known.</aside>
      <div class="page-title">
        <h1>{if @live_action == :task, do: "Task detail", else: label(Atom.to_string(@live_action))}</h1>
        <button :if={@live_action == :agents and @loaded and Agentboard.Captain.authorized?(@captain)} id="availability-open" type="button" phx-click="open_availability" aria-haspopup="dialog">Set availability</button>
        <p :if={@last_read}>Updated <time datetime={DateTime.to_iso8601(@last_read)}>{Calendar.strftime(@last_read,"%H:%M:%S UTC")}</time></p>
      </div>
      <aside :if={@unavailable} class="notice danger" role="alert">Board unavailable. <span :if={@last_read}>Showing the last successful read; retrying automatically.</span><span :if={!@last_read}>No board data has been loaded. Check readiness and migrations.</span></aside>
      <p :if={!@loaded and !@unavailable} class="notice" role="status">Connecting to the board…</p>
      <p :if={@live_action == :agents and Phoenix.Flash.get(@flash, :info)} class="notice" role="status">{Phoenix.Flash.get(@flash, :info)}</p>
      <p :if={@archive_error} class="notice danger" role="alert">{@archive_error}</p>
      <%= if @loaded do %>
        <%= case @live_action do %>
          <% view when view in [:board, :archive] -> %>
            <form action={path(@live_action)} method="get" class="filters">
              <label>Repository <input name="repo" value={@filters["repo"]} placeholder="All repositories" /></label>
              <label>Owner <input name="owner" value={@filters["owner"]} placeholder="All agents" /></label>
              <button type="submit">Filter board</button><a href={path(@live_action)}>Clear filters</a><a :if={@live_action==:board} href="/archive">Archived tasks</a>
            </form>
            <div :if={@live_action == :board} id="captain-waiting-count" phx-hook="CaptainWaitingCount" data-count={if @decision_unavailable, do: "?", else: @decisions["total"]} class="min-w-0">
              <a href="#captain-waiting">Waiting on captain <span class="count">{if @decision_unavailable, do: "?", else: @decisions["total"]}</span></a>
            </div>
            <AgentboardWeb.DecisionPanel.waiting :if={@live_action == :board} records={@decisions["decisions"]} answered={@decisions["answered"]} total={@decisions["total"]} answered_total={@decisions["answered_total"]} captain={@captain} unavailable={@decision_unavailable} />
            <a :if={@live_action == :board and @decisions["next_cursor"]} href={page_link(:board,@filters,@decisions["next_cursor"],"decision_cursor")}>Next waiting decisions</a>
            <div class={if @live_action==:archive,do: "board-columns archive-columns",else: "board-columns"}>
              <section :for={status <- @statuses} :if={Map.has_key?(@data["columns"],status)} class="column" aria-label={label(status)}>
                <h2><span class={"status-marker "<>status}></span>{label(status)}<span class="count">{@data["columns"][status]["total"]}</span></h2>
                <nav class="column-pagination" aria-label={label(status) <> " pages"}>
                  <p id={"page-status-" <> status} role="status" aria-live="polite">Page {@data["columns"][status]["page"]} · {length(@data["columns"][status]["tasks"])} shown · {@data["columns"][status]["total"]} total</p>
                  <div>
                    <button id={"previous-page-" <> status} type="button" phx-click="column_page" phx-value-status={status} phx-value-direction="prev" aria-label={"Previous " <> label(status) <> " page"} aria-describedby={"page-status-" <> status} disabled={!@data["columns"][status]["previous"]}>Prev</button>
                    <button id={"next-page-" <> status} type="button" phx-click="column_page" phx-value-status={status} phx-value-direction="next" aria-label={"Next " <> label(status) <> " page"} aria-describedby={"page-status-" <> status} disabled={is_nil(@data["columns"][status]["next_cursor"])}>Next</button>
                  </div>
                </nav>
                <p :if={@data["columns"][status]["tasks"]==[]} class="empty">No {String.replace(status,"_"," ")} tasks.</p>
                <.completed_card :for={task <- @data["columns"][status]["tasks"]} :if={status=="done"} task={task} archived={@live_action==:archive} captain={@captain} />
                <article :for={task <- @data["columns"][status]["tasks"]} :if={status != "done"} class="task-card">
                  <div class="card-meta"><span>{task["id"]}</span><span class="priority">P{task["priority"]}</span></div>
                  <h3><a href={"/tasks/"<>task["id"]}>{task["title"]}</a></h3>
                  <p>{task["repo"] || "No repository"}</p>
                  <div class="owner"><.agent_identity id={task["assignee_id"]} /></div>
                  <div class="flags"><span :if={task["held_by_decision"]} class="flag">Claim held by decision</span><span :if={task["requester_stale"]} class="flag warning">requester_stale</span><span :if={task["claim_expired"]} class="flag danger">Claim expired</span><span :if={owner_stale?(task,@data["roster"])} class="flag warning">Agent stale</span></div>
                  <.review_ci :if={status == "review" && task["pr_url"]} state={@review_ci[task["pr_url"]]} unavailable={@ci_unavailable || @unavailable} />
                  <AgentboardWeb.DuplicateNotice.notice finding={get_in(@review_ci, [task["pr_url"], :duplicate_of])} />
                  <div class="links"><a :if={task["issue_url"]} href={task["issue_url"]} target="_blank" rel="noopener noreferrer">Issue</a><a :if={task["pr_url"]} href={task["pr_url"]} target="_blank" rel="noopener noreferrer">Pull request</a></div>
                </article>

              </section>
            </div>

          <% :task -> %>
            <article class="task-detail">
              <div class="card-meta">{@data["task"]["id"]} <span class="flag">{label(@data["task"]["status"])} / P{@data["task"]["priority"]}</span></div>
              <h2>{@data["task"]["title"]}</h2><p class="description">{@data["task"]["description"]}</p>
              <p :if={@data["archive"]["archived_at"]} class="notice">Archived {@data["archive"]["archived_at"]}. This task remains Done and its records are retained.</p>
              <button :if={@data["task"]["status"]=="done" and Agentboard.Captain.authorized?(@captain)} type="button" phx-click="archive_task" phx-value-id={@data["task"]["id"]} phx-value-archived={if @data["archive"]["archived_at"],do: "false",else: "true"} phx-value-revision={@data["archive"]["revision"]}>{if @data["archive"]["archived_at"],do: "Restore to Done",else: "Archive task"}</button>
              <dl><dt>Worker delivery</dt><dd><AgentboardWeb.PRLive.delivery worker={@workers[@data["task"]["assignee_id"]]} /></dd><dt>Owner</dt><dd><.agent_identity id={@data["task"]["assignee_id"]} archived={not is_nil(@data["archive"]["archived_at"])} /></dd><dt>Assigned by</dt><dd>{@data["task"]["assigner_id"] || "None"}</dd><dt>Claimed</dt><dd>{@data["task"]["claimed_at"] || "No active claim"}</dd><dt>Lease expires</dt><dd>{@data["task"]["claim_expires_at"] || "No active lease"}</dd><dt>Revision</dt><dd>{@data["task"]["revision"]}</dd><dt>Repository</dt><dd>{@data["task"]["repo"] || "None"}</dd></dl>
              <div class="flags"><span :if={@data["task"]["held_by_decision"]} class="flag">Claim held by decision</span><span :if={@data["task"]["requester_stale"]} class="flag warning">requester_stale</span><span :if={@data["task"]["claim_expired"]} class="flag danger">Claim expired; explicit recovery required</span><span :if={owner_stale?(@data["task"],@data["roster"])} class="flag warning">Agent stale</span></div>
              <div class="links"><a :if={@data["task"]["issue_url"]} href={@data["task"]["issue_url"]} target="_blank" rel="noopener noreferrer">GitHub issue</a><a :if={@data["task"]["pr_url"]} href={@data["task"]["pr_url"]} target="_blank" rel="noopener noreferrer">GitHub pull request</a></div>
            </article>
            <AgentboardWeb.DuplicateNotice.notice finding={get_in(@review_ci, [@data["task"]["pr_url"], :duplicate_of])} />
            <AgentboardWeb.DecisionPanel.waiting records={@decisions["decisions"]} answered={@decisions["answered"]} total={@decisions["total"]} answered_total={@decisions["answered_total"]} captain={@captain} unavailable={@decision_unavailable} />
            <a :if={@decisions["next_cursor"]} href={page_link(:task,@filters,@decisions["next_cursor"],"decision_cursor")}>Next waiting decisions</a>
            <section class="timeline"><h2>Task history</h2>
              <article :for={event <- @data["events"]}><div class="event-heading"><strong>{label(event["kind"])}</strong><time>{event["created_at"]}</time></div><p class="attribution">{event["actor_id"]} / {event["model"]} / {event["harness"]} / revision {event["new_revision"]}</p><p :if={event["body"]} class="description">{event["body"]}</p></article>
              <a :if={@data["next_cursor"]} href={page_link(:task,@filters,@data["next_cursor"])}>Next history page</a>
            </section>
            <section class="timeline"><h2>Documentation</h2><p :if={@data["documents"]==[]} class="empty">No documentation attached.</p>
              <article :for={document <- @data["documents"]} class="event"><h3><a href={document["viewer_url"]}>{document["title"]}</a></h3><p>{document["kind"]} · {document["source_agent_id"]} · {document["model"]} / {document["harness"]}</p><p :if={document["proposal_name"]}>OpenSpec: {document["proposal_name"]}</p><p :if={document["source_revision"]}>Commit: {document["source_revision"]}</p><div class="links"><a href={document["download_url"]}>Download HTML</a><a :if={document["pr_url"]} href={document["pr_url"]} target="_blank" rel="noopener noreferrer">Pull request</a></div></article>
            </section>
            <section class="timeline"><h2>Task thread</h2><p :if={@data["messages"]==[]} class="empty">No messages on this task.</p>
              <.message :for={message <- @data["messages"]} message={message} />
              <a :if={@data["message_cursor"]} href={page_link(:task,@filters,@data["message_cursor"],"message_cursor")}>Next messages</a>
            </section>
          <% :agents -> %>
            <section :if={@data["authentication"]} id="agent-auth-report" class="notice">
              <h2>API identity observations</h2>
              <p :if={@data["authentication"]["status"] == "unavailable"}>Authentication report unavailable in mode {@data["authentication"]["mode"]}. Retained agent roster below remains current.</p>
              <div :if={@data["authentication"]["status"] != "unavailable"}>
              <p>Mode: {@data["authentication"]["mode"]} · Last {@data["authentication"]["window"]}. Observe retains header attribution; these counts report adoption.</p>
              <dl><dt>Anonymous</dt><dd>{@data["authentication"]["counts"]["anonymous"] || 0}</dd><dt>Invalid or revoked</dt><dd>{@data["authentication"]["counts"]["invalid"] || 0}</dd><dt>Actor mismatch</dt><dd>{@data["authentication"]["counts"]["actor_mismatch"] || 0}</dd><dt>Matched</dt><dd>{@data["authentication"]["counts"]["matched"] || 0}</dd></dl>
              <details><summary>Recent attribution evidence</summary><p :for={entry <- @data["authentication"]["recent"]}>{entry["created_at"]} · {entry["outcome"]} · attributed {entry["attributed_agent_id"] || "unregistered"} · verified {entry["verified_agent_id"] || "none"} · {entry["method"]} {entry["route"]}</p></details>
              </div>
            </section>
            <p><a href="/agents?waiting=true">Seats waiting on captain</a> · <a href="/agents">All seats</a> · <a href="/agents?kind=human">Human</a> · <a href="/agents?kind=system">System</a> · <a href="/agents?kind=fixture">Fixture</a> · <a href="/agents?kind=all&retired=true">Retired</a></p>
            <p :if={!Agentboard.Captain.authorized?(@captain)}><a href="/settings">Unlock captain controls</a></p>
            <p :if={@data["agents"]==[]} class="empty">No registered agents. Register a stable identity with <code>agentboard agent register</code>.</p>
            <div class="table-scroll"><table><thead><tr><th>Agent / harness</th><th>Model / host</th><th>Activity</th><th>Availability</th><th>Seat scope</th><th>Heartbeat (stale after {stale_label(@data["roster_stale_after"])})</th><th>Capabilities</th></tr></thead><tbody>
              <tr :for={agent <- @data["agents"]}><td><strong>{agent["name"]}</strong><p><.agent_identity id={agent["id"]} /> / {agent["harness"]}</p><p><span :if={agent["kind"] != "seat"} class="flag">{agent["kind"]}</span><span :if={agent["retired_at"]} class="flag warning">Retired</span></p></td><td>{agent["model"]}<p>{agent["host"] || "Host unknown"}</p></td><td>{agent["reported_status"] || "Not reported"}<span :if={agent["waiting_on_captain"]} class="flag warning">Waiting on captain</span><p><a :if={agent["current_task_id"]} href={"/tasks/"<>agent["current_task_id"]}>{agent["current_task_id"]}</a></p></td><td><span class={if agent["availability"]["state"] == "active", do: "flag healthy", else: "flag warning"}>{label(agent["availability"]["state"])}</span><p>{agent["availability"]["reason"]}</p><p :if={agent["availability"]["until"]}>Until {agent["availability"]["until"]}</p><p>Source: {agent["availability"]["source"]}</p><button :if={Agentboard.Captain.authorized?(@captain)} id={"availability-open-#{agent["id"]}"} type="button" class="text-button" phx-click="open_availability" phx-value-id={agent["id"]} aria-haspopup="dialog" aria-label={"Set availability for #{agent["id"]}"}>Set availability</button></td><td><.seat_scope agent={agent} captain={@captain} /></td><td><span class={if agent["stale"],do: "flag warning",else: "flag healthy"}>{if agent["stale"],do: "Stale",else: "Fresh"}</span><p :if={agent["stale"] and agent["reported_status"] == "busy"}>last reported busy (unreliable)</p><p>{agent["last_heartbeat"] || "Never"}</p><p>{age(agent["last_heartbeat"])}</p></td><td>{Enum.join(agent["capabilities"],", ")}<AgentboardWeb.PRLive.delivery worker={@workers[agent["id"]]} /></td></tr>
            </tbody></table></div>
            <.availability_modal :if={@availability_form != nil and Agentboard.Captain.authorized?(@captain)} form={@availability_form} error={@availability_error} return_focus={@availability_return_focus} />
            <.scope_modal :if={@scope_form != nil and Agentboard.Captain.authorized?(@captain)} form={@scope_form} error={@scope_error} />
            <a :if={@data["next_cursor"]} href={page_link(:agents,@filters,@data["next_cursor"])}>Next agents</a>
          <% :messages -> %>
            <form action="/messages" method="get" class="filters"><label>Recipient <input name="to" value={@filters["to"]} placeholder="All recipients" /></label><label>Task <input name="task" value={@filters["task"]} placeholder="All threads" /></label><label class="check"><input type="checkbox" name="unread" value="true" checked={@filters["unread"]=="true"} /> Unread only</label><button type="submit">Filter messages</button><a href="/messages">Clear filters</a></form>
            <p :if={@data["messages"]==[]} class="empty">No messages match these filters.</p>
            <section class="timeline"><.message :for={message <- @data["messages"]} message={message} /></section>
            <a :if={@data["next_cursor"]} href={page_link(:messages,@filters,@data["next_cursor"])}>Next messages</a>
          <% :quota -> %>
            <form action="/quota" method="get" class="filters"><label>Provider <input name="provider" value={@filters["provider"]} placeholder="All providers" /></label><label>Account <input name="account" value={@filters["account"]} placeholder="All accounts" /></label><button type="submit">Filter quota</button><a href="/quota">Clear filters</a></form>
            <p class="context">Reported quota is routing evidence. Unknown, stale, and untrusted readings are not available capacity.</p>
            <p :if={@data["quota"]==[]} class="empty">No quota observations yet. Collect a report with <code>quota-axi --json --max-age 90s | agentboard quota push --json</code>.</p>
            <div :if={@data["quota"] != []} class="table-scroll quota-summary">
              <table>
                <caption>Latest quota by provider and account. Select a row for windows, scope bounds, and collection details.</caption>
                <thead><tr><th scope="col">Provider / account</th><th scope="col">Effective remaining</th><th scope="col">Runway</th><th scope="col">Evidence</th><th scope="col">Collected</th><th scope="col"><span class="visually-hidden">Details</span></th></tr></thead>
                <tbody>
                  <tr :for={observation <- @data["quota"]} phx-click="open_quota" phx-value-id={observation["id"]} class="quota-row">
                    <td><strong>{observation["provider"]}</strong><p>{observation["account_key"]}</p></td>
                    <td>
                      <p :if={observation["scopes"] == []}>Unknown</p>
                      <div :for={scope <- observation["scopes"]} class="quota-summary-line"><span>{scope["scope"]}</span><strong>{if trustworthy?(observation, scope), do: remaining(%{"percent_remaining" => scope["effective_percent_remaining"]}), else: "Unknown"}</strong></div>
                    </td>
                    <td>
                      <p :if={observation["scopes"] == []}>Unknown</p>
                      <div :for={scope <- observation["scopes"]} class="quota-summary-line"><span>{scope["scope"]}</span><span class={if trustworthy?(observation,scope) and get_in(scope,["runway","status"]) == "exhausted_now", do: "flag danger", else: "quota-runway"}>{if trustworthy?(observation,scope), do: runway(scope), else: "Unknown"}</span></div>
                    </td>
                    <td><span class={if fresh?(observation), do: "flag healthy", else: "flag warning"}>{evidence_status(observation)}</span><p :if={Enum.any?(observation["scopes"], &(!trustworthy?(observation,&1)))}>Uncertain scope bounds</p></td>
                    <td><time datetime={observation["generated_at"]}>{age(observation["generated_at"])}</time><p>{observation["source_agent_id"]}</p></td>
                    <td><button id={"quota-details-#{observation["id"]}"} type="button" class="quota-detail-button" aria-haspopup="dialog" aria-label={"View quota details for #{observation["provider"]} / #{observation["account_key"]}"}>Details <span aria-hidden="true">↗</span></button></td>
                  </tr>
                </tbody>
              </table>
            </div>
            <.quota_modal :if={@quota_detail} observation={@quota_detail} />
            <a :if={@data["next_cursor"]} href={page_link(:quota,@filters,@data["next_cursor"])}>Next quota accounts</a>
        <% end %>
      <% end %>
    </main>
    """
  end

  attr(:form, :map, required: true)
  attr(:error, :any, required: true)
  attr(:return_focus, :string, required: true)

  defp availability_modal(assigns) do
    ~H"""
    <dialog id="availability-dialog" phx-hook="QuotaDialog" phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")} class="quota-dialog availability-dialog" aria-labelledby="availability-title" data-return-focus={@return_focus} data-close-event="close_availability">
      <header class="quota-dialog-header"><h2 id="availability-title">Set availability</h2><button type="button" phx-click="close_availability" aria-label="Close availability controls" autofocus>Close</button></header>
      <form phx-submit="set_availability" phx-change="availability_draft" class="settings-form">
        <p>Use an agent override, or a harness/model selector. Reserved and out-of-service require a reason. Current task ownership is retained.</p>
        <p :if={@error} role="alert" class="notice danger break-words">{@error}</p>
        <label>Agent ID (override)<input name="agent_id" value={@form["agent_id"]} placeholder="codex-example-agent-a" /></label>
        <label>Harness (default)<input name="harness" value={@form["harness"]} placeholder="claude" /></label>
        <label>Model pattern (default)<input name="model_pattern" value={@form["model_pattern"]} placeholder="glm-*" /></label>
        <label>State<select name="state"><option :for={{value, name} <- [{"active", "Active"}, {"reserved", "Reserved"}, {"out_of_service", "Out of service"}]} value={value} selected={@form["state"] == value}>{name}</option></select></label>
        <label :if={@form["state"] in ~w(reserved out_of_service)}>Reason<input name="reason" value={@form["reason"]} /></label>
        <label :if={@form["state"] == "out_of_service"}>Until (out of service, RFC3339)<input name="until" value={@form["until"]} placeholder="2026-10-12T00:00:00Z" /></label>
        <div class="flex flex-wrap gap-3"><button type="submit">Save availability</button><button type="button" class="text-button" phx-click="close_availability">Cancel</button></div>
      </form>
    </dialog>
    """
  end

  attr(:agent, :map, required: true)
  attr(:captain, :any, default: nil)

  @doc false
  def seat_scope(assigns) do
    assigns = assign(assigns, :scope, assigns.agent["scope"])

    ~H"""
    <div id={"seat-scope-#{@agent["id"]}"}>
      <%= if @scope do %>
        <span class={if @scope["state"] == "managed", do: "flag healthy", else: "flag warning"}>{label(@scope["state"])}</span>
        <%= if @scope["state"] == "managed" do %>
          <p>Revision {@scope["revision"]}</p>
          <dl>
            <dt>Allowed repositories</dt><dd><ul><li :for={repo <- @scope["allowed_repos"]}><code class="whitespace-pre-wrap">{repo}</code></li></ul></dd>
            <dt>Required labels (all)</dt><dd><span :if={@scope["required_labels"] == []}>No required-label gate</span><ul><li :for={label <- @scope["required_labels"]}><code class="whitespace-pre-wrap">{label}</code></li></ul></dd>
            <dt>Allowed labels (any)</dt><dd><span :if={@scope["allowed_labels"] == []}>No allowed-label gate</span><ul><li :for={label <- @scope["allowed_labels"]}><code class="whitespace-pre-wrap">{label}</code></li></ul></dd>
          </dl>
          <p>Repository and label gates must all pass. Additional task labels are allowed.</p>
          <p>Managed scope alone does not enable automatic claiming.</p>
          <p>Changed by {@scope["changed_by"]} at {@scope["updated_at"]}</p>
        <% else %>
          <p>No captain-managed scope. Legacy manual admission remains; automatic claiming is not authorized.</p>
        <% end %>
        <button :if={Agentboard.Captain.authorized?(@captain)} id={"scope-open-#{@agent["id"]}"} type="button" class="text-button" phx-click="open_scope" phx-value-id={@agent["id"]} aria-haspopup="dialog" aria-label={"Edit seat scope for #{@agent["id"]}"}>Edit scope</button>
      <% else %>
        <span class="flag warning">Scope unavailable</span>
      <% end %>
    </div>
    """
  end

  attr(:form, :map, required: true)
  attr(:error, :any, default: nil)

  @doc false
  def scope_modal(assigns) do
    ~H"""
    <dialog id="scope-dialog" phx-hook="QuotaDialog" phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")} class="quota-dialog availability-dialog" aria-labelledby="scope-title" data-return-focus={"scope-open-#{@form["agent_id"]}"} data-close-event="close_scope">
      <header class="quota-dialog-header"><h2 id="scope-title">Edit seat scope</h2><button type="button" phx-click="close_scope" aria-label="Close seat scope editor" autofocus>Close</button></header>
      <form phx-submit="set_scope" phx-change="scope_draft" class="settings-form">
        <p>Agent <strong>{@form["agent_id"]}</strong> · Expected revision {@form["revision"]}</p>
        <p>Saving replaces the complete scope. At least one explicit owner/repo is required; no wildcards. Enter one repository or exact label per line. Label case and spaces are preserved.</p>
        <p>Every required label and at least one allowed label must match, when supplied. Empty label fields disable that gate. Additional task labels are allowed.</p>
        <p :if={@error} role="alert" class="notice danger break-words">{@error}</p>
        <label>Allowed repositories<textarea name="allowed_repos" rows="4" class="w-full min-w-0" required placeholder="owner/repo">{@form["allowed_repos"]}</textarea></label>
        <label>Required labels (all)<textarea name="required_labels" rows="3" class="w-full min-w-0">{@form["required_labels"]}</textarea></label>
        <label>Allowed labels (any)<textarea name="allowed_labels" rows="3" class="w-full min-w-0">{@form["allowed_labels"]}</textarea></label>
        <div class="flex flex-wrap gap-3"><button type="submit">Save scope</button><button type="button" class="text-button" phx-click="close_scope">Cancel</button></div>
      </form>
    </dialog>
    """
  end

  attr(:observation, :map, required: true)

  defp quota_modal(assigns) do
    ~H"""
    <dialog id="quota-detail-dialog" phx-hook="QuotaDialog" class="quota-dialog" aria-labelledby="quota-detail-title" data-return-focus={"quota-details-#{@observation["id"]}"}>
      <header class="quota-dialog-header"><h2 id="quota-detail-title">Quota details</h2><button type="button" phx-click="close_quota" aria-label="Close quota details" autofocus>Close</button></header>
      <section class="quota-observation">
              <h2>{@observation["provider"]}<span class="account">{@observation["account_key"]}</span><span class={if @observation["state"]["status"]=="fresh" and !@observation["state"]["stale"] and !@observation["observation_stale"],do: "flag healthy",else: "flag warning"}>{@observation["state"]["status"]}{if @observation["observation_stale"],do: " / observation old",else: ""}</span></h2>
              <p class="attribution">Collected by {@observation["source_agent_id"]} / {@observation["model"]} / {@observation["harness"]}. Generated {@observation["generated_at"]}.</p>
              <p :if={@observation["state"]["error"]} class="notice warning">{@observation["state"]["error"]}</p>
              <p :if={@observation["windows"]==[]} class="empty">No reported windows in this observation.</p>
              <div class="table-scroll"><table><thead><tr><th>Window</th><th>Reported remaining</th><th>Used</th><th>Reset</th></tr></thead><tbody><tr :for={window <- @observation["windows"]}><td>{window["label"]}<p>{window["id"]} / {window["kind"]}<span :if={window["share_of"]}> / share of {window["share_of"]}</span><span :if={window["id"] in Map.get(@observation["state"],"untrusted_window_ids",[])} class="flag warning">Untrusted</span></p></td><td>{remaining(window)}</td><td>{if is_number(window["percent_used"]),do: "#{window["percent_used"]}%",else: "Unknown"}</td><td>{window["resets_at"] || window["reset_text"] || "Unknown"}</td></tr></tbody></table></div>
              <div class="scopes"><article :for={scope <- @observation["scopes"]} class={if get_in(scope,["runway","status"])=="exhausted_now",do: "scope exhausted",else: "scope"}>
                <h3>{scope["scope"]}<span class="flag">{if trustworthy?(@observation,scope),do: scope["status"],else: "Uncertain"}</span></h3>
                <dl><dt>Effective remaining</dt><dd>{if trustworthy?(@observation,scope) and is_number(scope["effective_percent_remaining"]),do: "#{scope["effective_percent_remaining"]}%",else: "Unknown"}</dd><dt>Runway (reported)</dt><dd>{value(get_in(scope,["runway","status"]))}<span :if={get_in(scope,["runway","usable_runway_seconds"]) != nil}> / {get_in(scope,["runway","usable_runway_seconds"])} seconds</span></dd><dt>Spend priority (advisory)</dt><dd>{value(get_in(scope,["selection","spend_priority"]))}</dd></dl>
                <p :if={scope["bound_conflict"]} class="notice warning">Producer reports contradictory bounds.</p>
              </article></div>

      </section>
    </dialog>
    """
  end

  attr(:id, :string, default: nil)
  attr(:archived, :boolean, default: false)

  def agent_identity(assigns) do
    ~H"""
    <a :if={@id} href={(if @archived, do: "/archive", else: "/") <> "?" <> URI.encode_query(%{"owner" => @id})} aria-label={"View tasks owned by " <> @id}><code class="select-all [overflow-wrap:anywhere]">{@id}</code></a><span :if={is_nil(@id)}>Unassigned</span>
    """
  end

  defp completed_card(assigns) do
    ~H"""
    <details id={"completed-"<>@task["id"]} class="task-card completed-card" phx-hook="CompletedCard">
      <summary title={@task["title"]}><strong>{@task["title"]}</strong><span>{@task["repo"] || "No repository"}</span></summary>
      <div class="completed-detail">
        <div class="card-meta"><span>{@task["id"]}</span><span>P{@task["priority"]}</span></div>
        <p class="owner"><.agent_identity id={@task["assignee_id"]} archived={@archived} /></p>
        <div class="links"><a href={"/tasks/"<>@task["id"]}>Task history &amp; docs</a><a :if={@task["pr_url"]} href={@task["pr_url"]} target="_blank" rel="noopener noreferrer">Pull request</a><a :if={@task["issue_url"]} href={@task["issue_url"]} target="_blank" rel="noopener noreferrer">Issue</a></div>
        <button :if={Agentboard.Captain.authorized?(@captain)} type="button" phx-click="archive_task" phx-value-id={@task["id"]} phx-value-archived={if @archived,do: "false",else: "true"} phx-value-revision={@task["archive_revision"]}>{if @archived,do: "Restore to Done",else: "Archive task"}</button>
        <a :if={!Agentboard.Captain.authorized?(@captain)} href="/settings">Unlock archive controls</a>
      </div>
    </details>
    """
  end

  defp fresh?(observation),
    do:
      observation["state"]["status"] == "fresh" and observation["state"]["stale"] != true and
        observation["observation_stale"] != true

  defp evidence_status(observation) do
    cond do
      observation["observation_stale"] == true ->
        "Observation old"

      observation["state"]["stale"] == true and observation["state"]["status"] == "fresh" ->
        "Stale"

      true ->
        label(observation["state"]["status"])
    end
  end

  defp runway(scope) do
    case get_in(scope, ["runway", "status"]) do
      "exhausted_now" ->
        "Exhausted now"

      "through_reset" ->
        "Through reset"

      "projected_exhaustion" ->
        case get_in(scope, ["runway", "usable_runway_seconds"]) do
          n when is_number(n) -> "~#{round(n / 60)} min"
          _ -> "Projected exhaustion"
        end

      _ ->
        "Unknown"
    end
  end

  attr(:message, :map, required: true)

  defp message(assigns) do
    ~H"""
    <article class="message"><div class="event-heading"><strong>{@message["sender_id"]} to {@message["recipient_id"] || "task thread"}</strong><time>{@message["created_at"]}</time></div><p class="attribution">{@message["model"]} / {@message["harness"]}<span :if={@message["recipient_id"]}> / {if @message["read_at"],do: "Read",else: "Unread"}</span> <a :if={@message["task_id"]} href={"/tasks/"<>@message["task_id"]}>{@message["task_id"]}</a></p><p class="description">{@message["body"]}</p></article>
    """
  end
end
