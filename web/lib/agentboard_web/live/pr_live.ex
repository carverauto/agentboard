defmodule AgentboardWeb.PRLive do
  use Phoenix.LiveView, layout: false
  alias AgentboardWeb.BranchFlowComponents, as: Flow
  alias AgentboardWeb.BranchInspectionComponents, as: Inspect
  alias Agentboard.Delivery.BranchFlow
  alias Agentboard.Delivery.BranchFlow.RepositoryRoles

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 5000)

    {:ok,
     assign(socket,
       data: nil,
       error: nil,
       params: %{},
       card_repositories: nil,
       selected_inspection: nil,
       route_generation: 0,
       inspection_generation: 0,
       client_generation: 0,
       graph_visible: true,
       glyphs_visible: true,
       inspection_notice: nil,
       branch_flow: Application.get_env(:agentboard, :branch_flow_enabled, false)
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    # Reads are synchronous within this LiveView process. Navigation and refresh
    # cannot race an async result from an older route into the new selection.
    changed = socket.assigns.params != params
    socket = assign(socket, params: params)

    socket =
      if changed do
        socket
        |> assign(route_generation: socket.assigns.route_generation + 1)
        |> dismiss_inspection(nil)
        |> clear_old_table()
      else
        socket
      end

    {:noreply, load(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = load(socket)
    # Schedule after completion: slow reads never accumulate timer work.
    Process.send_after(self(), :refresh, 5000)
    {:noreply, socket}
  end

  @impl true
  def handle_event("search_prs", %{"q" => query}, socket) when is_binary(query) do
    if socket.assigns.branch_flow do
      {:noreply,
       push_patch(socket,
         to: Flow.path(socket.assigns.params, %{"q" => query, "cursor" => nil}),
         replace: true
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("search_repositories", %{"chooser_q" => query}, socket)
      when is_binary(query) do
    if socket.assigns.branch_flow do
      {:noreply,
       push_patch(socket,
         to: Flow.path(socket.assigns.params, %{"chooser_q" => query, "chooser_cursor" => nil}),
         replace: true
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("apply_repository_order", _, socket) do
    if socket.assigns.branch_flow do
      {:noreply,
       socket
       |> assign(card_repositories: nil)
       |> load()
       |> push_event("branch-flow-focus", %{id: "branch-repositories-heading"})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("inspect_pr", %{"id" => id, "mode" => mode} = params, socket) do
    if valid_intent?(socket, params) and mode in ["topology", "table"] and
         visible_pr?(socket, mode, id) and (mode != "table" or socket.assigns.glyphs_visible) do
      socket = assign(socket, client_generation: integer(params["client_generation"]))

      if socket.assigns.selected_inspection == %{id: id, mode: mode} and mode == "table" do
        {:noreply, dismiss_inspection(socket, nil)}
      else
        {:noreply,
         socket
         |> assign(
           selected_inspection: %{id: id, mode: mode},
           inspection_generation: socket.assigns.inspection_generation + 1,
           inspection_notice: nil
         )
         |> load()}
      end
    else
      if valid_intent?(socket, params) and mode in ["topology", "table"] do
        {:noreply,
         socket
         |> assign(client_generation: integer(params["client_generation"]))
         |> dismiss_inspection(
           "Selected PR is no longer available on this page. Inspection closed."
         )}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("close_inspection", params, socket) do
    if valid_intent?(socket, params) and
         (integer(params["generation"]) == socket.assigns.inspection_generation or
            socket.assigns.selected_inspection == %{id: params["id"], mode: params["mode"]}) do
      {:noreply,
       socket
       |> assign(client_generation: integer(params["client_generation"]))
       |> dismiss_inspection(nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(event, params, socket)
      when event in ["toggle_branch_graph", "toggle_branch_glyphs"] do
    if valid_intent?(socket, params) do
      key = if event == "toggle_branch_graph", do: :graph_visible, else: :glyphs_visible

      socket =
        assign(socket, [
          {key, not socket.assigns[key]},
          {:client_generation, integer(params["client_generation"])}
        ])

      socket =
        if (key == :glyphs_visible and not socket.assigns.glyphs_visible and
              socket.assigns.selected_inspection) &&
             socket.assigns.selected_inspection.mode == "table",
           do: dismiss_inspection(socket, nil),
           else: socket

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp valid_intent?(socket, params) when is_map(params) do
    socket.assigns.branch_flow and is_nil(socket.assigns.params["id"]) and
      integer(params["route_generation"]) == socket.assigns.route_generation and
      is_integer(integer(params["client_generation"])) and
      integer(params["client_generation"]) > socket.assigns.client_generation
  end

  defp valid_intent?(_, _), do: false

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) and byte_size(value) < 20 do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil

  defp visible_pr?(%{assigns: %{data: data}}, "topology", id) when is_map(data) do
    Enum.any?(get_in(data, [:topology, :relations]) || [], &(&1.id == id))
  end

  defp visible_pr?(%{assigns: %{data: data}}, "table", id) when is_map(data) do
    Enum.any?(get_in(data, [:table, :prs]) || [], &(&1.pr["id"] == id))
  end

  defp visible_pr?(_, _, _), do: false

  defp dismiss_inspection(socket, notice) do
    data = socket.assigns.data
    data = if is_map(data), do: Map.put(data, :inspection, nil), else: data

    assign(socket,
      selected_inspection: nil,
      inspection_generation: socket.assigns.inspection_generation + 1,
      inspection_notice: notice,
      data: data
    )
  end

  defp clear_old_table(%{assigns: %{branch_flow: true, data: %{table: table} = data}} = socket) do
    # A failed new route must never show another selection's rows. Global
    # obligations remain visible as explicitly last-known if the read fails.
    assign(socket,
      data:
        %{
          data
          | table: %{
              table
              | prs: [],
                total: nil,
                previous_cursor: nil,
                next_cursor: nil,
                error: "Selected PR view unavailable; retry this selection"
            }
        }
        |> Map.put(:prs, [])
        |> Map.put(:topology, nil)
        |> Map.put(:inspection, nil)
    )
  end

  defp clear_old_table(socket), do: assign(socket, data: nil)

  defp load(socket) do
    read =
      cond do
        socket.assigns.params["id"] ->
          Agentboard.Delivery.Reads.detail(socket.assigns.params["id"])

        socket.assigns.branch_flow ->
          BranchFlow.list(socket.assigns.params,
            card_repositories: socket.assigns.card_repositories,
            inspection_id:
              socket.assigns.selected_inspection && socket.assigns.selected_inspection.id,
            inspection_mode:
              socket.assigns.selected_inspection && socket.assigns.selected_inspection.mode
          )

        true ->
          Agentboard.Delivery.Reads.list(socket.assigns.params)
      end

    case read do
      {:ok, %{table: table} = data} ->
        order = Enum.map(data.cards, & &1.repository)

        socket =
          assign(socket,
            data: Map.put(data, :prs, table.prs),
            error: nil,
            card_repositories: order
          )

        if not is_nil(socket.assigns.selected_inspection) and
             (is_nil(data.inspection) or data.inspection.available == false) do
          dismiss_inspection(
            socket,
            "Selected PR is no longer available on this page. Inspection closed."
          )
        else
          socket
        end

      {:ok, data} ->
        assign(socket, data: data, error: nil)

      {:error, _, reason} ->
        socket
        |> assign(error: reason)
        |> degrade_branch_data()
        |> dismiss_inspection(
          if(socket.assigns.selected_inspection,
            do: "Inspection closed because current evidence could not be read.",
            else: nil
          )
        )
    end
  end

  defp degrade_branch_data(%{assigns: %{data: %{table: table} = data}} = socket) do
    qualify = fn relation ->
      Map.merge(relation, %{
        fresh: false,
        ci_state: if(relation.ci_state == "failing", do: "failing", else: "unknown"),
        merge_state: if(relation.merge_state == "conflicting", do: "stale", else: "unknown"),
        mergeable: nil,
        mergeable_state: nil,
        source_currentness_error: "Last-known relation; current evidence could not be read."
      })
    end

    topology =
      if data.topology do
        data.topology
        |> Map.update!(:relations, &Enum.map(&1, qualify))
        |> Map.update(:repository_role, nil, &RepositoryRoles.degrade/1)
      end

    rows = Enum.map(table.prs, &Map.update!(&1, :relation, qualify))

    cards =
      Enum.map(
        data.cards,
        fn card ->
          card
          |> Map.update!(:relations, fn relations -> Enum.map(relations, qualify) end)
          |> Map.update(:repository_role, nil, &RepositoryRoles.degrade/1)
          |> Map.put(:default_branch, nil)
        end
      )

    assign(socket,
      data:
        %{data | topology: topology, table: %{table | prs: rows}, prs: rows, cards: cards}
        |> Map.put(
          :repository_roles,
          Map.new(
            Map.get(data, :repository_roles, %{}),
            fn {repository, role} -> {repository, RepositoryRoles.degrade(role)} end
          )
        )
    )
  end

  defp degrade_branch_data(socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <main id="pr-view" phx-hook="BranchFlowView" data-route-generation={@route_generation} data-inspection-generation={@inspection_generation} data-client-generation={@client_generation} data-selected-inspection={@selected_inspection && @selected_inspection.id} data-inspection-mode={@selected_inspection && @selected_inspection.mode}>
      <p id="branch-inspection-status" class="visually-hidden" role="status" aria-live="polite">{@inspection_notice}</p>
      <div class="page-title"><h1>Pull requests</h1><p>CI responsibility persists after agents change tasks.</p></div>
      <aside :if={@error} class="notice danger" role="alert">{@error}. Retained data is last known; fresh CI cannot be verified.</aside>
      <%= if @data do %>
        <aside :if={Map.get(@data, :github_budget)} class="notice">
          GitHub budget {@data.github_budget.remaining}/{@data.github_budget.capacity} per minute
          <span :if={@data.github_budget.provider_blocked}> · Provider cooldown until {to_string(@data.github_budget.blocked_until)}</span>
        </aside>
        <%= if Map.has_key?(@data, :prs) do %>
          <%= if Map.has_key?(@data, :table) do %>
            <Flow.attention data={@data} params={@params} degraded={not is_nil(@error)} />
            <Flow.overview data={@data} params={@params} />
            <Inspect.topology data={@data} params={@params} graph_visible={@graph_visible} />
            <Flow.filters data={@data} params={@params} />
            <div class="branch-controls"><button id="branch-toggle-glyphs" type="button" data-branch-toggle="toggle_branch_glyphs" aria-pressed={to_string(@glyphs_visible)}>{if @glyphs_visible, do: "Hide relationship glyphs", else: "Show relationship glyphs"}</button></div>
          <% else %>
          <section id="default-branch-health" class="task-detail min-w-0">
            <h2>Default-branch health</h2>
            <p>Retained workflow obligations · observation {if Agentboard.Delivery.Scheduling.enabled?(), do: "enabled", else: "disabled"}. A webhook feed is required; absence of failures does not verify green.</p>
            <p :if={@data.default_branch_health == []}>No retained red default-branch runs.</p>
            <article :for={run <- @data.default_branch_health} class="min-w-0 break-all">
              <h3><a href={run["source_url"]} target="_blank" rel="noopener noreferrer">{run["repository"]} · {run["workflow_name"]}</a></h3>
              <p><span class="flag danger">{run["conclusion"]}</span> · branch {run["branch"]} · {run["head_sha"]} · run {run["run_id"]}, attempt {run["run_attempt"]}</p>
              <p>Red since {run["failed_at"]} · routed to {run["responsible_id"] || "Coordinator not configured"} · sources {Enum.join(run["source_tasks"], ", ")}</p>
              <p :if={run["last_error"]} class="flag warning">Latest collection deferred: {run["last_error"]}. Retained evidence only.</p>
              <p :for={job <- run["jobs"]}><a href={job["url"]} target="_blank" rel="noopener noreferrer">{job["name"]} / {Enum.join(job["steps"], ", ")}</a></p>
            </article>
            <p :if={length(@data.default_branch_health) > 50} class="flag warning">Additional obligations exist; health is not green.</p>
          </section>
          <.link patch={if @params["show_terminal"] == "true", do: "/prs", else: "/prs?show_terminal=true"}>{if @params["show_terminal"] == "true", do: "Hide merged/closed", else: "Show merged/closed"}</.link>
          <% end %>
          <div class="table-scroll" tabindex="0" role="region" aria-label="Pull requests, scroll for all columns"><table class="pr-list"><thead><tr><th scope="col">Pull request / head</th><th scope="col">CI / mergeability</th><th scope="col">Responsible / repair</th><th scope="col">Delivery / progress</th></tr></thead><tbody>
            <%= for row <- @data.prs do %>
            <tr data-branch-pr={row.pr["id"]}>
              <td><a href={"/prs/" <> URI.encode_www_form(row.pr["id"])}>{row.pr["owner"]}/{row.pr["repo"]} #{row.pr["number"]}</a><p>{row.poll && row.poll["lifecycle"] || "Lifecycle unknown"}</p><AgentboardWeb.DuplicateNotice.notice finding={row.duplicate_of} /><p class="break-all">{row.poll && row.poll["head_sha"] || "Head unknown"}</p><Inspect.glyph :if={Map.has_key?(@data, :table) and @glyphs_visible} relation={row.relation} selected={@selected_inspection} /></td>
              <td><span class={if row.ci_state == "failing", do: "flag danger", else: "flag"}>{if not is_nil(@error) and row.ci_state != "failing", do: "unknown", else: row.ci_state}</span><p>{if row.fresh and is_nil(@error), do: "Fresh observation", else: "Unknown or stale evidence"}</p><p>{row.poll && row.poll["last_error"]}</p><p :if={Map.get(row, :source_currentness_error)} class="flag warning">{row.source_currentness_error}</p><p :if={row.poll_deferral_age > 0}>Poll deferred {row.poll_deferral_age}s</p><p><span class={if row.merge_state == "conflicting", do: "flag danger", else: "flag"}>Merge {if @error, do: "unknown", else: row.merge_state}</span></p><p :if={row.base_ref}>Base {row.base_ref} · {row.mergeable_state || "computing"}</p></td>
              <td><%= if row.obligation do %><a :if={row.obligation["responsible_id"]} href={"/agents?owner=" <> row.obligation["responsible_id"]}>{row.obligation["responsible_id"]}</a><span :if={!row.obligation["responsible_id"]}>Captain queue</span><p><a href={"/tasks/" <> row.obligation["repair_task_id"]}>{row.obligation["state"]} · episode {row.obligation["episode"]}</a></p><% else %>No CI failure episode<% end %><.rebase follow_up={row.rebase_follow_up} /><AgentboardWeb.ConflictOrderNotice.notice projection={row.conflict_order} unavailable={not is_nil(@error)} /></td>
              <td><.delivery worker={row.worker} /><.progress obligation={row.obligation} overdue={row.overdue} /><.decisions records={row.decisions} /></td>
            </tr>
            <tr :if={Map.has_key?(@data, :table) and not is_nil(@data.inspection) and @data.inspection.mode == "table" and @data.inspection.id == row.pr["id"]} id="branch-inspection-row">
              <td colspan="4"><Inspect.inspection inspection={@data.inspection} as_of={@data.as_of} generation={@inspection_generation} /></td>
            </tr>
            <% end %>
          </tbody></table></div>
          <%= if Map.has_key?(@data, :table) do %>
            <Flow.pagination id="branch-table-pagination" label="Pull request pages" section={@data.table} params={@params} cursor="cursor" />
          <% else %>
            <a :if={@data.next_cursor} href={"/prs?" <> URI.encode_query(%{"cursor" => @data.next_cursor, "show_terminal" => @params["show_terminal"] || "false"})}>Next PRs</a>
          <% end %>
        <% else %>
          <AgentboardWeb.DuplicateNotice.notice finding={@data.duplicate_of} />
          <p :if={@data.poll_deferral_age > 0}>Poll deferred {@data.poll_deferral_age}s</p><article id="pr-delivery-progress" class="task-detail"><h2><a href={@data.pr["url"]} target="_blank" rel="noopener noreferrer">{@data.pr["owner"]}/{@data.pr["repo"]} #{@data.pr["number"]}</a></h2><p>CI {if @error, do: "unknown", else: @data.ci_state} · {if @data.fresh and is_nil(@error), do: "Fresh observation", else: "Stale or unknown"}</p><p class="break-all">Head {@data.poll && @data.poll["head_sha"] || "unknown"}</p><p :if={@data.obligation}><a href={"/tasks/" <> @data.obligation["repair_task_id"]}>Repair {@data.obligation["state"]}</a> · {@data.obligation["responsible_id"] || "Captain queue"}</p><p>Merge {if @error, do: "unknown", else: @data.merge_state} · provider {@data.mergeable_state || "unknown"} · base {@data.base_ref || "unknown"}</p><.rebase follow_up={@data.rebase_follow_up} /><AgentboardWeb.ConflictOrderNotice.notice projection={@data.conflict_order} unavailable={not is_nil(@error)} /><.delivery worker={@data.worker} /><.progress obligation={@data.obligation} overdue={@data.overdue} /><.decisions records={@data.decisions} /></article>
          <section class="timeline"><h2>Immutable submission sources</h2><article :for={source <- @data.sources}><a href={"/tasks/" <> source["task_id"]}>{source["task_id"]}</a><p>{source["submitted_by_id"] || "Unknown submitter"} · {source["attribution"]}</p></article></section>
          <section class="timeline"><h2>Observed attempts</h2><p>Evidence is source links only. Missing required policy, incomplete collection and stale evidence cannot verify recovery.</p><article :for={observation <- @data.observations}><h3>{observation.ci_state} · {to_string(observation.observed_at)}</h3><p class="break-all">{observation.head_sha}</p><p>Policy {observation.payload["policy"]} · tested ref {observation.payload["tested_ref"]}</p><p>Merge {observation.payload["mergeable_state"] || "unknown"} · mergeable {inspect(observation.payload["mergeable"])} · base {observation.payload["base_ref"] || "unknown"}</p><.observed_attempts attempts={observation.payload["attempts"] || []} /></article></section>
        <% end %>
      <% end %>
    </main>
    """
  end

  defp decisions(assigns) do
    ~H"""
    <p :for={r <- @records} class="min-w-0 break-all">
      <a href={"/tasks/" <> r["task_id"]}>Waiting on captain · {r["requester_id"]} · {r["status"]}</a>
      <span :if={r["requester_stale"]} class="flag warning">requester_stale · explicit recovery required</span>
    </p>
    """
  end

  defp rebase(assigns) do
    ~H"""
    <div :if={@follow_up} class="min-w-0">
      <p><a href={"/tasks/" <> @follow_up["repair_task_id"]}>Rebase follow-up</a> · {@follow_up["responsible_id"] || "Captain queue"}</p>
      <p>{if @follow_up["resolved_at"], do: "Conflict signal resolved; repair completion is explicit", else: "Conflict follow-up pending"}</p>
    </div>
    """
  end

  defp observed_attempts(assigns) do
    # The history read already caps observations at 20; cap each visible table too.
    rows = Enum.take(assigns.attempts, 101)
    assigns = assign(assigns, rows: Enum.take(rows, 100), truncated: length(rows) > 100)

    ~H"""
    <p :if={@rows == []} class="empty">No observed attempts.</p>
    <div :if={@rows != []} class="table-scroll" tabindex="0" role="region" aria-label="Observed attempts, scroll for all columns">
      <table class="table-auto min-w-[60rem]">
        <thead>
          <tr>
            <th scope="col">Name</th><th scope="col">Kind</th>
            <th scope="col">Status / conclusion</th><th scope="col">Latest</th>
            <th scope="col">Started</th><th scope="col">Completed</th><th scope="col">Source</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={attempt <- @rows}>
            <td class="break-all">{attempt["name"] || "Unknown"}</td>
            <td>{attempt["kind"] || "Unknown"}</td>
            <td>{attempt["status"] || "unknown"} / <span class={if attempt["conclusion"] in ~w(failure error timed_out cancelled action_required startup_failure), do: "flag danger", else: "flag"}>{attempt["conclusion"] || "pending"}</span></td>
            <td>{if attempt["latest"], do: "Latest", else: "Superseded"}</td>
            <td>{attempt["started_at"] || "Not observed"}</td>
            <td>{attempt["completed_at"] || "Not observed"}</td>
            <td>
              <a :if={attempt["source_url"] || attempt["details_url"]} href={attempt["source_url"] || attempt["details_url"]} target="_blank" rel="noopener noreferrer">{"View #{attempt["conclusion"] || attempt["status"] || "unknown"} source"}</a>
              <span :if={!(attempt["source_url"] || attempt["details_url"])}>Unavailable</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <p :if={@truncated} class="text-muted">Showing the first 100 attempts in this observation.</p>
    """
  end

  defp progress(assigns) do
    ~H"""
    <div :if={@obligation}>
      <p>Progress {@obligation["last_progress_at"]}</p>
      <p :if={@overdue} class="flag warning">Reminder overdue</p>
      <p :if={@obligation["escalated_at"]} class="flag warning">Captain escalation</p>
      <p :if={@obligation["blocker"]}>{@obligation["blocker"]}</p>
    </div>
    """
  end

  def delivery(assigns) do
    ~H"""
    <div :if={@worker} class="delivery-summary">
      <p>{cond do @worker.revoked -> "Revoked"; not @worker.enabled -> "Disabled"; @worker.paused -> "Paused"; true -> "Enabled" end} · connector {@worker.binding["connector_state"]} / {if @worker.connector_fresh, do: "fresh", else: "stale"}</p>
      <p>Adapter {@worker.binding["adapter_state"]} · {@worker.binding["adapter"] || "Unknown"} {@worker.binding["adapter_version"]}</p>
      <p>Pending {@worker.pending} · received {@worker.received} · handled {@worker.handled}</p><p :if={@worker.uncertainty} class="flag warning">Submission uncertain; reconciliation required</p><p>{@worker.binding["reason"]}</p>
      <details><summary>Declared adapter capabilities</summary><p :for={{name, value} <- @worker.binding["capabilities"]}>{name}: {if value["supported"], do: "supported", else: "unsupported"} · {value["reason"]}</p></details>
    </div><span :if={!@worker}>Worker not enrolled</span>
    """
  end
end
