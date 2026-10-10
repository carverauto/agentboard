defmodule AgentboardWeb.BranchInspectionComponents do
  @moduledoc "Bounded observed relationships and a single read-only PR inspection."
  use Phoenix.Component
  alias AgentboardWeb.BranchFlowComponents, as: Flow

  def topology(assigns) do
    section = Map.get(assigns.data, :topology)

    assigns =
      assign(assigns, section: section, graph: graph((section && section.relations) || []))

    ~H"""
    <section :if={@section && is_binary(@params["repo"])} id="branch-topology" class="branch-section" aria-labelledby="branch-topology-heading">
      <h2 id="branch-topology-heading" tabindex="-1">Observed PR relationships · {@params["repo"]}</h2>
      <p><.link patch={Flow.repo_path(@params, nil)}>Back to all repositories</.link></p>
      <Flow.default_role role={Map.get(@section, :repository_role)} as_of={@data.as_of} />
      <p>Integration role/health unavailable · Ahead/behind unavailable</p>
      <p>Observed PR targets, not commit ancestry or merge paths. Ref endpoints retain their exact repository and observed SHA; no current branch tip is inferred.</p>
      <p :if={is_integer(@section.total)}>Showing {if @section.relations == [], do: 0, else: @section.offset + 1}–{@section.offset + length(@section.relations)} of {@section.total} matching tracked open PRs · twenty relations per page.</p>
      <p :if={!is_integer(@section.total)}>Tracked open relationship count unavailable.</p>
      <p>Database snapshot <Flow.stamp value={@data.as_of} />. Provider observation ages remain independent.</p>
      <p :if={@section.error} class="notice warning" role="alert">{@section.error}</p>
      <div class="branch-controls"><button id="branch-toggle-graph" type="button" data-branch-toggle="toggle_branch_graph" aria-pressed={to_string(@graph_visible)}>{if @graph_visible, do: "Hide relationship graph", else: "Show relationship graph"}</button></div>
      <p :if={@section.relations == []}>No available tracked open PR relationships on this page.</p>
      <%= if @graph_visible and @section.relations != [] do %>
        <p :if={@graph.error} class="notice">{@graph.error} The exact observed relationships remain listed below.</p>
        <div :if={!@graph.error} class="branch-graph-scroll" role="region" tabindex="0" aria-label="Observed relationship schematic, scroll horizontally. Full text follows.">
          <svg id="branch-relationship-graph" class="branch-graph" viewBox={"0 0 840 #{@graph.height}"} style={"height: #{@graph.height}px"} aria-hidden="true" focusable="false">
            <defs><marker id="branch-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 Z" fill="currentColor" /></marker></defs>
            <g :for={edge <- @graph.edges} data-branch-connector={edge.id}>
              <path d={edge.path} fill="none" stroke="currentColor" marker-end="url(#branch-arrow)" />
              <text x={edge.x} y={edge.y} class="branch-graph-pr">#{edge.number}</text>
            </g>
            <g :for={node <- @graph.nodes} data-branch-endpoint={node.id}>
              <circle cx={node.x} cy={node.y} r="5" fill="currentColor" />
              <text x={node.x + 10} y={node.y - 8}><tspan x={node.x + 10}>{label(node.repo <> ":" <> node.ref)}</tspan><tspan x={node.x + 10} dy="16">{short(node.sha)}</tspan></text>
            </g>
          </svg>
        </div>
      <% end %>
      <ol id="branch-topology-relations" class="branch-topology-list" aria-label="Exact observed base to head relationships">
        <li :for={relation <- @section.relations} data-branch-topology-relation={relation.id}>
          <h3><button id={"branch-node-" <> relation.id} type="button" data-branch-inspect={relation.id} data-mode="topology" aria-haspopup="dialog" aria-expanded={to_string(inspection_selected?(@data.inspection, relation.id, "topology"))} aria-controls="branch-inspection">Inspect PR #{relation.number}</button></h3>
          <.pair relation={relation} />
          <.qualification relation={relation} as_of={@data.as_of} />
          <p :if={Map.get(relation, :off_page_parent)} class="text-muted">Exact retained parent relationship is outside this page: <a href={"/prs/" <> relation.off_page_parent.id}>PR #{relation.off_page_parent.number}</a>. Continuation only; no ancestry loaded.</p>
          <p :if={Map.get(relation, :off_page_parent_ambiguous)} class="text-muted">Multiple retained PR heads match this exact base; no single parent is asserted.</p>
          <.inspection :if={inspection_selected?(@data.inspection, relation.id, "topology")} inspection={@data.inspection} as_of={@data.as_of} generation={nil} />
        </li>
      </ol>
      <Flow.pagination id="branch-topology-pagination" label="Observed relationship pages" section={@section} params={@params} cursor="topology_cursor" />
    </section>
    """
  end

  def glyph(assigns) do
    ~H"""
    <div class="branch-glyph" data-branch-glyph={@relation.id}>
      <p class="break-all">{@relation.base_repo || "Base repository unknown"}:{@relation.base_ref || "Base ref unknown"} <span aria-hidden="true">→</span><span class="visually-hidden"> observed target to head </span> {@relation.head_repo || "Head repository unknown"}:{@relation.head_ref || "Head ref unknown"}</p>
      <p>{divergence(@relation)}</p>
      <button id={"branch-disclose-" <> @relation.id} type="button" data-branch-inspect={@relation.id} data-mode="table" aria-expanded={to_string(@selected == %{id: @relation.id, mode: "table"})} aria-controls="branch-inspection">{if @selected == %{id: @relation.id, mode: "table"}, do: "Hide", else: "Inspect"} PR #{@relation.number} relationship</button>
    </div>
    """
  end

  def inspection(assigns) do
    assigns =
      assign(assigns, row: assigns.inspection.record, relation: assigns.inspection.relation)

    ~H"""
    <section id="branch-inspection" class="branch-inspection" data-branch-inspection={@inspection.id} data-mode={@inspection.mode} role={if @inspection.mode == "topology", do: "dialog", else: "region"} aria-modal={if @inspection.mode == "topology", do: "false", else: nil} aria-labelledby="branch-inspection-heading">
      <div class="branch-controls"><h3 id="branch-inspection-heading" tabindex="-1">PR #{@relation.number} · {@relation.repository}</h3><button id="branch-inspection-close" type="button" data-branch-close="true" aria-label={"Close PR #" <> @relation.number <> " inspection"}>Close</button></div>
      <p><a href={@relation.url} target="_blank" rel="noopener noreferrer">View PR on GitHub</a> · <a href={@inspection.detail_path}>Full PR details and retained history</a></p>
      <p>Title not retained</p>
      <p :if={@inspection.error} class="notice warning">{@inspection.error}</p>
      <.pair relation={@relation} />
      <p class="break-all">Expected base tip: {@relation.expected_base_sha || "unavailable"}. Integration role/health unavailable.</p>
      <Flow.default_role role={Map.get(@inspection, :repository_role)} as_of={@as_of} />
      <.qualification relation={@relation} as_of={@as_of} />
      <p class="break-all">Retained snapshot {if @relation.metadata_available, do: "(exact source matched)", else: "(unqualified source)"}: {Map.get(@relation, :snapshot_id) || "unavailable"} · snapshot generation {@relation.snapshot_generation || "unavailable"} · poll generation {@relation.poll_generation || "unavailable"}</p>
      <p :if={@row.poll && @row.poll["last_error"]}>Collection deferred/error: {@row.poll["last_error"]}</p>
      <p :if={@row.poll_deferral_age > 0}>Poll deferred {@row.poll_deferral_age}s</p>
      <div class="branch-inspection-grid">
        <section aria-label="Immutable submission attribution"><h4>Immutable submission attribution</h4>
          <p :if={@inspection.sources == []}>Submission source unavailable</p>
          <p :for={source <- @inspection.sources} data-branch-submission-source={source["id"] || source["task_id"]}><a href={"/tasks/" <> URI.encode_www_form(source["task_id"])}>{source["task_id"]}</a> · submitter {source["submitted_by_id"] || "unknown"} · {source["attribution"]}</p>
          <p :if={@inspection.sources_truncated}>Showing ten sources; more retained sources are in full PR details.</p>
        </section>
        <section aria-label="CI responsibility"><h4>CI responsibility</h4>
          <%= if @row.obligation do %><p>{@row.obligation["responsible_id"] || "Captain queue"} · <a href={"/tasks/" <> URI.encode_www_form(@row.obligation["repair_task_id"])}>Repair {@row.obligation["state"]}</a> · episode {@row.obligation["episode"]}</p><% else %><p>No CI failure episode</p><% end %>
        </section>
        <section aria-label="Rebase responsibility"><h4>Rebase responsibility</h4>
          <%= if @row.rebase_follow_up do %><p>{@row.rebase_follow_up["responsible_id"] || "Captain queue"} · <a href={"/tasks/" <> URI.encode_www_form(@row.rebase_follow_up["repair_task_id"])}>Rebase repair</a></p><p>{if @row.rebase_follow_up["resolved_at"], do: "Conflict signal resolved; repair completion is explicit", else: "Conflict follow-up pending"}</p><% else %><p>No retained rebase follow-up</p><% end %>
        </section>
        <section aria-label="Delivery and progress"><h4>Delivery and progress</h4>
          <AgentboardWeb.PRLive.delivery worker={@row.worker} />
          <p :if={@row.obligation}>Last progress <Flow.stamp value={@row.obligation["last_progress_at"]} as_of={@as_of} /> · {if @row.overdue, do: "Overdue", else: "No current overdue flag"}</p>
          <p><a href={@inspection.detail_path}>Delivery, decisions and progress details</a></p>
        </section>
      </div>
      <section aria-label="Retained failure sources"><h4>Retained failure sources</h4>
        <p :if={@inspection.failures == []}>No matching retained failed-attempt sources. This does not verify passing CI.</p>
        <p :for={failure <- @inspection.failures} data-branch-failure-source={failure.identity || failure.provider_id || failure.name}><a :if={(failure.source_url || failure.details_url)} href={(failure.source_url || failure.details_url)} target="_blank" rel="noopener noreferrer">{failure.name || "Observed failure"}</a><span :if={!(failure.source_url || failure.details_url)}>{failure.name || "Observed failure"} · source URL unavailable</span> · {failure.kind || "kind unavailable"} · {failure.conclusion || failure.status || "state unavailable"} · {if failure.latest, do: "Latest retained attempt", else: "Superseded retained attempt"}</p>
        <p :if={@inspection.failures_truncated}>Showing ten failure sources; more retained evidence is in full PR details.</p>
      </section>
    </section>
    """
  end

  def pair(assigns) do
    ~H"""
    <p class="branch-pair break-all"><span>Observed base: {@relation.base_repo || "repository unknown"}:{@relation.base_ref || "ref unknown"} · {@relation.base_sha || "SHA unknown"}</span><span aria-hidden="true"> → </span><span class="visually-hidden"> observed PR target to </span><span>Head: {@relation.head_repo || "repository unknown"}:{@relation.head_ref || "ref unknown"} · {@relation.head_sha || "SHA unknown"}</span></p>
    """
  end

  def qualification(assigns) do
    ~H"""
    <p><span class={if @relation.ci_state == "failing", do: "flag danger", else: "flag"}>CI {@relation.ci_state}</span> · <span class={if @relation.merge_state == "conflicting", do: "flag danger", else: "flag"}>Merge {@relation.merge_state}</span> · {if @relation.fresh, do: "Fresh observation", else: "Unknown or stale evidence"} · {divergence(@relation)}</p>
    <p>Observed <Flow.stamp value={@relation.observed_at} as_of={@as_of} /></p>
    <p :if={@relation.source_currentness_error} class="flag warning">{@relation.source_currentness_error}</p>
    """
  end

  defp divergence(relation) do
    if relation.fresh and Map.get(relation, :mergeable_state) == "behind",
      do: "Behind base; count unavailable",
      else: "Ahead/behind unavailable"
  end

  defp inspection_selected?(nil, _, _), do: false

  defp inspection_selected?(inspection, id, mode),
    do: inspection.id == id and inspection.mode == mode

  defp short(sha), do: String.slice(sha, 0, 10)

  defp label(value),
    do: if(String.length(value) > 32, do: String.slice(value, 0, 31) <> "…", else: value)

  @doc "A schematic of exact observed endpoints, never an inferred ancestry DAG."
  def graph(relations) do
    pairs = Enum.map(relations, &{endpoint(&1, :base), endpoint(&1, :head), &1})
    endpoints = pairs |> Enum.flat_map(fn {base, head, _} -> [base, head] end) |> Enum.uniq()

    ambiguous =
      endpoints
      |> Enum.reject(&is_nil/1)
      |> Enum.group_by(fn {repo, ref, _} -> {repo, ref} end)
      |> Enum.any?(fn {_, values} -> length(values) > 1 end)

    adjacency =
      Enum.reduce(pairs, %{}, fn {base, head, _}, result ->
        Map.update(result, base, [head], &[head | &1])
      end)

    reason =
      cond do
        nil in endpoints ->
          "Some exact endpoint identities are unavailable; no branch topology is inferred."

        ambiguous ->
          "The same ref has different retained SHAs on this page; no single branch tip is asserted."

        Enum.any?(endpoints, &cycle?(&1, adjacency, MapSet.new())) ->
          "Observed target relationships contain a cycle; they are not an ancestry graph."

        true ->
          nil
      end

    if reason do
      %{error: reason, nodes: [], edges: [], height: 0}
    else
      bases = MapSet.new(Enum.map(pairs, &elem(&1, 0)))
      heads = MapSet.new(Enum.map(pairs, &elem(&1, 1)))

      columns =
        Enum.group_by(endpoints, fn point ->
          cond do
            MapSet.member?(bases, point) and MapSet.member?(heads, point) -> 1
            MapSet.member?(bases, point) -> 0
            true -> 2
          end
        end)

      nodes =
        for column <- 0..2,
            {point, index} <- Enum.with_index(Map.get(columns, column, [])),
            do: node(point, column, index)

      by_point = Map.new(nodes, &{&1.point, &1})

      edges =
        Enum.map(pairs, fn {base, head, relation} ->
          from = by_point[base]
          to = by_point[head]

          %{
            id: relation.id,
            number: relation.number,
            x: div(from.x + to.x, 2),
            y: div(from.y + to.y, 2) - 5,
            path:
              "M #{from.x + 6} #{from.y} C #{from.x + 65} #{from.y}, #{to.x - 65} #{to.y}, #{to.x - 7} #{to.y}"
          }
        end)

      %{
        error: nil,
        nodes: nodes,
        edges: edges,
        height: max(90, Enum.max(Enum.map(nodes, & &1.y), fn -> 0 end) + 36)
      }
    end
  end

  defp endpoint(relation, side) do
    values =
      Enum.map([:repo, :ref, :sha], &Map.get(relation, String.to_existing_atom("#{side}_#{&1}")))

    if Enum.all?(values, &(is_binary(&1) and &1 != "")), do: List.to_tuple(values)
  end

  defp node({repo, ref, sha} = point, column, index) do
    %{
      id: :crypto.hash(:sha256, :erlang.term_to_binary(point)) |> Base.encode16(case: :lower),
      point: point,
      repo: repo,
      ref: ref,
      sha: sha,
      x: 20 + column * 280,
      y: 40 + index * 58
    }
  end

  defp cycle?(point, graph, seen) do
    MapSet.member?(seen, point) or
      Enum.any?(Map.get(graph, point, []), &cycle?(&1, graph, MapSet.put(seen, point)))
  end
end
