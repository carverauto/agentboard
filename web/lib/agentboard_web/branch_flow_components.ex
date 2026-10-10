defmodule AgentboardWeb.BranchFlowComponents do
  @moduledoc "Read-only, bounded branch overview components; no provider or settings writes."
  use Phoenix.Component

  defdelegate path(params, changes \\ %{}), to: Agentboard.Delivery.BranchFlow.Route

  def repo_path(params, repository) do
    path(params, %{
      "repo" => repository,
      "node_kind" => nil,
      "node" => nil,
      "view" => if(repository, do: "repo", else: "overview"),
      "cursor" => nil,
      "topology_cursor" => nil
    })
  end

  def node_path(params, repository, kind, node) do
    path(params, %{
      "repo" => repository,
      "view" => "repo",
      "node_kind" => kind,
      "node" => node,
      "cursor" => nil,
      "topology_cursor" => nil
    })
  end

  def attention(assigns) do
    assigns = assign(assigns, section: assigns.data.attention)

    ~H"""
    <section id="branch-attention" class="branch-section" aria-labelledby="branch-attention-heading">
      <h2 id="branch-attention-heading">Branch attention</h2>
      <p>Retained workflow obligations · observation {if @section.enabled, do: "enabled", else: "disabled"}. A webhook feed is required; absence of failures does not verify green.</p>
      <p :if={@degraded} class="flag warning">Last-known attention; the latest database read failed.</p>
      <p><%= if is_integer(@section.total) do %>{@section.total} retained red runs across all repositories.<% else %>Retained red count unavailable.<% end %></p>
      <%= if @section.oldest do %>
        <article id="branch-oldest-failure" class="notice danger" aria-label="Oldest global retained failure">
          <h3>Oldest retained failure: {@section.oldest["repository"]} · {@section.oldest["branch"]} · {@section.oldest["workflow_name"]}</h3>
          <p>Red since <.stamp value={@section.oldest["failed_at"]} as_of={@data.as_of} /> · routed to {@section.oldest["responsible_id"] || "Coordinator not configured; captain queue"}</p>
          <p>Run {@section.oldest["run_id"]}, attempt {@section.oldest["run_attempt"]} · head <span class="break-all">{@section.oldest["head_sha"]}</span></p>
          <p>Observed <.stamp value={@section.oldest["observed_at"]} as_of={@data.as_of} /></p>
          <span :if={Map.get(@section.oldest, :stale, false)} class="flag warning">Stale observation; unresolved obligation remains red</span>
          <span :if={!Enum.any?(@data.cards, &(&1.repository == @section.oldest["repository"]))} class="flag">Outside strip</span>
          <.link patch={repo_path(@params, @section.oldest["repository"])}>Focus {@section.oldest["repository"]}</.link>
          · <a href={@section.oldest["source_url"]} target="_blank" rel="noopener noreferrer">View oldest workflow</a>
          <p :if={@section.oldest["last_error"]}>Collection deferred: {@section.oldest["last_error"]}. Unresolved evidence remains red.</p>
        </article>
      <% end %>
      <p :if={Map.get(@section, :oldest_available) == false} class="notice warning">Oldest retained failure unavailable; the feed is degraded.</p>
      <p :if={@section.total == 0}>No retained red runs; current branch health unknown.</p>
      <p :if={Map.get(@section, :error)} class="notice warning" role="alert">{@section.error}</p>
      <div id="branch-attention-runs">
        <article :for={run <- @section.runs} data-branch-run={run["id"]} class="branch-run">
          <span :if={Map.get(run, :outside_strip, false)} class="flag">Outside strip</span>
          <h3><a href={run["source_url"]} target="_blank" rel="noopener noreferrer">{run["repository"]} · {run["workflow_name"]}</a></h3>
          <p><span class="flag danger">! Retained {run["conclusion"]}</span> · branch {run["branch"]} · <span class="break-all">{run["head_sha"]}</span> · run {run["run_id"]}, attempt {run["run_attempt"]}</p>
          <p>Red since <.stamp value={run["failed_at"]} as_of={@data.as_of} /> · observed <.stamp value={run["observed_at"]} as_of={@data.as_of} /></p>
          <span :if={Map.get(run, :stale, false)} class="flag warning">Stale observation; unresolved obligation remains red</span>
          <p>Routed to {run["responsible_id"] || "Coordinator not configured; captain queue"} · source tasks:
            <span :if={run["source_tasks"] == []}>unavailable</span>
            <a :for={task <- run["source_tasks"]} href={"/tasks/" <> URI.encode_www_form(task)} class="branch-source">{task}</a>
          </p>
          <p :if={run["last_error"]} class="flag warning">Latest collection deferred: {run["last_error"]}. Retained evidence only.</p>
          <p :for={job <- Enum.take(run["jobs"], 10)}><a href={job["url"]} target="_blank" rel="noopener noreferrer">{job["name"]} / {Enum.join(Enum.take(job["steps"] || [], 10), ", ")}</a></p>
          <.link patch={repo_path(@params, run["repository"])}>Focus {run["repository"]}</.link>
        </article>
      </div>
      <p :if={is_integer(@section.total) and @section.total > length(@section.runs)}>Showing {length(@section.runs)} of {@section.total} retained red runs; more failures remain.</p>
      <.pagination id="branch-attention-pagination" label="Retained failure pages" section={@section} params={@params} cursor="attention_cursor" />
    </section>
    """
  end

  def overview(assigns) do
    current = Enum.map(assigns.data.cards, & &1.repository)
    assigns = assign(assigns, order_changed: current != assigns.data.ranked_repositories)

    ~H"""
    <section id="branch-repositories" class="branch-section" aria-labelledby="branch-repositories-heading">
      <h2 id="branch-repositories-heading" tabindex="-1">Tracked repositories</h2>
      <p>Local tracked delivery inventory · {count(@data.inventory_count)} repositories. Counts cover retained local records, not every GitHub PR.</p>
      <p class="text-muted">Preview: eligible captain pins first, then busiest tracked repositories. Integration intake, default-branch metadata, integration health and ahead/behind counts remain unavailable in this slice.</p>
      <p><a href="/settings#branch-flow-settings">Manage captain repository pins</a></p>
      <p :if={get_in(@data, [:settings, :error])} class="notice warning" role="alert">{@data.settings.error}</p>
      <p class="text-muted">Snapshot <.stamp value={@data.as_of} />. A refreshed database view does not renew provider evidence.</p>
      <div class="branch-controls">
        <.link patch={repo_path(@params, nil)} aria-current={if is_nil(@params["repo"]), do: "page", else: nil}>All repositories</.link>
        <button id="branch-apply-order" type="button" phx-click="apply_repository_order" disabled={!@order_changed}>
          {if @order_changed, do: "Repository order updated; apply new order", else: "Repository order current"}
        </button>
      </div>
      <p :if={@data.inventory_count == 0} class="empty">No tracked repositories. Branch names and health are unknown.</p>
      <p :if={is_nil(@data.inventory_count)} class="notice warning">Repository ranking and counts unavailable. Retained failures remain global.</p>
      <div class="branch-repo-strip" role="region" aria-label="Up to five pinned and busiest tracked repositories">
        <article :for={card <- @data.cards} id={"branch-repo-" <> identity(card.repository)} data-branch-repo={card.repository} class="branch-repo-card">
          <p :if={Map.get(card, :pin_position)} class="flag">Captain pin {card.pin_position}</p>
          <h3><.link patch={repo_path(@params, card.repository)} aria-current={if @params["repo"] == card.repository, do: "page", else: nil}>Focus {card.repository}</.link></h3>
          <%= if Map.get(card, :available, true) do %>
            <p>{count(card.open_count)} tracked open · {count(card.unknown_lifecycle_count)} lifecycle unknown · {count(card.terminal_count)} retained terminal</p>
            <p><span class={if is_integer(card.red_count) and card.red_count > 0, do: "flag danger", else: "flag"}>{if is_integer(card.red_count) and card.red_count > 0, do: "! #{card.red_count} retained red", else: if(is_integer(card.red_count), do: "? No retained red; health unknown", else: "? Retained red count unavailable; health unknown")}</span></p>
            <p :if={Map.get(card, :error)} class="flag warning">{card.error}</p>
            <p class="text-muted">Default branch unknown · integration health unavailable · ahead/behind unavailable</p>
            <p class="text-muted">Up to three tracked PRs in canonical order; risk ranking pending.</p>
            <p :if={Map.get(card, :relations_error)} class="flag warning">{card.relations_error}</p>
            <ul class="branch-relations" aria-label={"Observed PR relations for " <> card.repository}>
              <li :for={relation <- card.relations} data-branch-relation={relation.id}>
                <.relation relation={relation} repository={card.repository} params={@params} as_of={@data.as_of} />
              </li>
            </ul>
            <p :if={card.relations == []}>No available tracked open PR relations.</p>
            <.link :if={is_integer(card.open_count) and card.open_count > length(card.relations)} patch={repo_path(@params, card.repository)}>+{card.open_count - length(card.relations)} tracked open PRs</.link>
          <% else %>
            <p class="flag warning">{Map.get(card, :error) || "Repository no longer available"}. Apply the updated order to refresh this card.</p>
          <% end %>
        </article>
      </div>
      <details id="branch-repo-chooser" class="branch-chooser" phx-hook="CompletedCard">
        <summary>Choose a repository · {if is_integer(@data.overflow_count), do: "+#{@data.overflow_count}", else: "count unavailable"} outside the strip</summary>
        <p>All tracked repositories, twenty per page. Choosing a repository only filters this view.</p>
        <form id="branch-chooser-form" class="filters" phx-change="search_repositories" phx-submit="search_repositories">
          <label for="branch-chooser-search">Search repository names
            <input id="branch-chooser-search" name="chooser_q" type="search" maxlength="120" value={text_param(@params, "chooser_q")} phx-debounce="300" />
          </label>
        </form>
        <p :if={Map.get(@data.chooser, :error)} role="alert" class="notice warning">{@data.chooser.error}</p>
        <p>{count(@data.chooser.total)} matching repositories</p>
        <ul>
          <li :for={repo <- @data.chooser.repositories} data-branch-chooser-repo={repo.repository}>
            <.link patch={repo_path(@params, repo.repository)} aria-current={if @params["repo"] == repo.repository, do: "page", else: nil}>{repo.repository}</.link>
            · {count(repo.open_count)} tracked open · {count(repo.unknown_lifecycle_count)} lifecycle unknown · {count(repo.red_count)} retained red
          </li>
        </ul>
        <.pagination id="branch-chooser-pagination" label="Repository chooser pages" section={@data.chooser} params={@params} cursor="chooser_cursor" />
      </details>
    </section>
    """
  end

  def relation(assigns) do
    ~H"""
    <p>
      <.link :if={@relation.base_ref} patch={node_path(@params, @repository, "base", @relation.base_ref)} aria-label={"Filter " <> @repository <> " by exact base " <> @relation.base_ref}>{@relation.base_ref}</.link>
      <span :if={!@relation.base_ref}>Base unknown</span>
      <span aria-hidden="true"> → </span><span class="visually-hidden"> targets head </span>
      <.link patch={node_path(@params, @repository, "pr", @relation.id)} aria-label={"Filter " <> @repository <> " to PR #" <> @relation.number}>#{@relation.number} · {@relation.head_repo || "Head repository unknown"}:{@relation.head_ref || "Head ref unknown"}</.link>
    </p>
    <p class="text-muted">Observed target only · health unknown · <.stamp value={@relation.observed_at} as_of={@as_of} /></p>
    """
  end

  def filters(assigns) do
    ~H"""
    <section class="branch-section" aria-labelledby="branch-table-heading">
      <h2 id="branch-table-heading" tabindex="-1">Tracked PRs{if is_binary(@params["repo"]), do: " · " <> @params["repo"], else: ""}</h2>
      <div class="branch-controls">
        <.link :if={@params["repo"]} patch={repo_path(@params, nil)}>Clear repository filter</.link>
        <span :if={@params["node_kind"] in ["base", "pr"] and is_binary(@params["node"])} class="flag">Selected {@params["node_kind"]}: {@params["node"]}</span>
        <.link :if={@params["node_kind"] || @params["node"]} patch={path(@params, %{"node_kind" => nil, "node" => nil, "cursor" => nil, "topology_cursor" => nil})}>Clear node filter</.link>
      </div>
      <p :if={Map.get(@data.table, :error)} role="alert" class="notice warning">{@data.table.error}. Invalid filters never show an unfiltered table. <.link patch={path(@params, %{"repo" => nil, "node_kind" => nil, "node" => nil, "q" => nil, "cursor" => nil, "topology_cursor" => nil, "view" => "overview", "show_terminal" => nil})}>Reset table filters</.link></p>
      <p :if={is_nil(@data.table.total)}>Matching tracked PR count unavailable.</p>
      <p :if={is_integer(@data.table.total)} role="status" aria-live="polite">{@data.table.total} matching tracked PRs · twenty rows per page</p>
      <p :if={@data.table.total == 0}>No tracked PRs match this selection.</p>
      <form id="branch-filter-form" class="filters" phx-change="search_prs" phx-submit="search_prs">
        <label for="branch-pr-search">Search tracked PR number or branch
          <input id="branch-pr-search" type="search" name="q" value={text_param(@params, "q")} maxlength="120" phx-debounce="300" />
        </label>
        <.link :if={@params["q"]} patch={path(@params, %{"q" => nil, "cursor" => nil})}>Clear search</.link>
        <.link id="branch-terminal-toggle" patch={path(@params, %{"show_terminal" => if(@params["show_terminal"] == "true", do: nil, else: "true"), "cursor" => nil})}>{if @params["show_terminal"] == "true", do: "Hide merged/closed", else: "Show merged/closed"}</.link>
      </form>
    </section>
    """
  end

  def pagination(assigns) do
    ~H"""
    <nav id={@id} class="branch-controls" aria-label={@label}>
      <.link :if={@section.previous_cursor} id={@id <> "-previous"} patch={path(@params, %{@cursor => @section.previous_cursor})}>Previous</.link>
      <.link :if={@section.next_cursor} id={@id <> "-next"} patch={path(@params, %{@cursor => @section.next_cursor})}>Next</.link>
      <.link :if={@params[@cursor]} id={@id <> "-reset"} patch={path(@params, %{@cursor => nil})}>Reset page</.link>
    </nav>
    """
  end

  def stamp(assigns) do
    stamp = datetime(assigns.value)
    as_of = datetime(Map.get(assigns, :as_of))
    seconds = if stamp && as_of, do: max(0, DateTime.diff(as_of, stamp))
    assigns = assign(assigns, stamp: stamp, seconds: seconds)

    ~H"""
    <time :if={@stamp} datetime={DateTime.to_iso8601(@stamp)}>{Calendar.strftime(@stamp, "%Y-%m-%d %H:%M:%S UTC")}</time><span :if={is_integer(@seconds)}> ({@seconds}s ago)</span><span :if={!@stamp}>not observed</span>
    """
  end

  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, stamp, _} -> stamp
      _ -> nil
    end
  end

  defp datetime(_), do: nil

  defp text_param(params, key) do
    case params[key] do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp count(value) when is_integer(value), do: Integer.to_string(value)
  defp count(_), do: "Count unavailable"

  defp identity(repository), do: :crypto.hash(:sha256, repository) |> Base.encode16(case: :lower)
end
