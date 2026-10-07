defmodule AgentboardWeb.PRLive do
  use Phoenix.LiveView, layout: false
  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 5000)
    {:ok, assign(socket, data: nil, error: nil, params: %{})}
  end

  @impl true
  def handle_params(params, _, socket), do: {:noreply, load(assign(socket, params: params))}
  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 5000)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    read =
      if socket.assigns.params["id"],
        do: Agentboard.Delivery.Reads.detail(socket.assigns.params["id"]),
        else: Agentboard.Delivery.Reads.list(socket.assigns.params)

    case read do
      {:ok, data} -> assign(socket, data: data, error: nil)
      {:error, _, reason} -> assign(socket, error: reason)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="pr-view">
      <div class="page-title"><h1>Pull requests</h1><p>CI responsibility persists after agents change tasks.</p></div>
      <aside :if={@error} class="notice danger" role="alert">{@error}. Retained data is last known; fresh CI cannot be verified.</aside>
      <%= if @data do %>
        <%= if Map.has_key?(@data, :prs) do %>
          <.link patch={if @params["show_terminal"] == "true", do: "/prs", else: "/prs?show_terminal=true"}>{if @params["show_terminal"] == "true", do: "Hide merged/closed", else: "Show merged/closed"}</.link>
          <div class="table-scroll" tabindex="0" role="region" aria-label="Pull requests, scroll for all columns"><table class="pr-list"><thead><tr><th>Pull request / head</th><th>CI / freshness</th><th>Responsible / repair</th><th>Delivery / progress</th></tr></thead><tbody>
            <tr :for={row <- @data.prs}>
              <td><a href={"/prs/" <> URI.encode_www_form(row.pr["id"])}>{row.pr["owner"]}/{row.pr["repo"]} #{row.pr["number"]}</a><p>{row.poll && row.poll["lifecycle"] || "Lifecycle unknown"}</p><p class="break-all">{row.poll && row.poll["head_sha"] || "Head unknown"}</p></td>
              <td><span class={if row.ci_state == "failing", do: "flag danger", else: "flag"}>{if @error, do: "unknown", else: row.ci_state}</span><p>{if row.fresh and is_nil(@error), do: "Fresh observation", else: "Unknown or stale evidence"}</p><p>{row.poll && row.poll["last_error"]}</p></td>
              <td><%= if row.obligation do %><a :if={row.obligation["responsible_id"]} href={"/agents?owner=" <> row.obligation["responsible_id"]}>{row.obligation["responsible_id"]}</a><span :if={!row.obligation["responsible_id"]}>Captain queue</span><p><a href={"/tasks/" <> row.obligation["repair_task_id"]}>{row.obligation["state"]} · episode {row.obligation["episode"]}</a></p><% else %>No failure episode<% end %></td>
              <td><.delivery worker={row.worker} /><.progress obligation={row.obligation} overdue={row.overdue} /></td>
            </tr>
          </tbody></table></div>
          <a :if={@data.next_cursor} href={"/prs?" <> URI.encode_query(%{"cursor" => @data.next_cursor, "show_terminal" => @params["show_terminal"] || "false"})}>Next PRs</a>
        <% else %>
          <article class="task-detail"><h2><a href={@data.pr["url"]} target="_blank" rel="noopener noreferrer">{@data.pr["owner"]}/{@data.pr["repo"]} #{@data.pr["number"]}</a></h2><p>CI {if @error, do: "unknown", else: @data.ci_state} · {if @data.fresh and is_nil(@error), do: "Fresh observation", else: "Stale or unknown"}</p><p class="break-all">Head {@data.poll && @data.poll["head_sha"] || "unknown"}</p><p :if={@data.obligation}><a href={"/tasks/" <> @data.obligation["repair_task_id"]}>Repair {@data.obligation["state"]}</a> · {@data.obligation["responsible_id"] || "Captain queue"}</p><.delivery worker={@data.worker} /><.progress obligation={@data.obligation} overdue={@data.overdue} /></article>
          <section class="timeline"><h2>Immutable submission sources</h2><article :for={source <- @data.sources}><a href={"/tasks/" <> source["task_id"]}>{source["task_id"]}</a><p>{source["submitted_by_id"] || "Unknown submitter"} · {source["attribution"]}</p></article></section>
          <section class="timeline"><h2>Observed attempts</h2><p>Evidence is source links only. Missing required policy, incomplete collection and stale evidence cannot verify recovery.</p><article :for={observation <- @data.observations}><h3>{observation.ci_state} · {to_string(observation.observed_at)}</h3><p class="break-all">{observation.head_sha}</p><p>Policy {observation.payload["policy"]} · tested ref {observation.payload["tested_ref"]}</p><.observed_attempts attempts={observation.payload["attempts"] || []} /></article></section>
        <% end %>
      <% end %>
    </main>
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
