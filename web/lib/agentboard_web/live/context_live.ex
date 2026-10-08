defmodule AgentboardWeb.ContextLive do
  use Phoenix.LiveView, layout: false
  alias Agentboard.Context

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 5000)

    {:ok,
     assign(socket,
       filters: %{},
       repos: load_repos(),
       data: nil,
       error: nil,
       param_error: nil,
       loaded: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case resolve_repo(params) do
      {:ok, resolved} ->
        filters =
          resolved
          |> Map.take(~w(id repo task kind q cursor))
          |> Map.reject(fn {_key, value} -> value == "" end)

        socket = assign(socket, filters: filters, param_error: nil)
        {:noreply, if(connected?(socket), do: reload(socket), else: socket)}

      {:error, message} ->
        {:noreply,
         assign(socket,
           filters: %{},
           data: nil,
           error: message,
           param_error: message,
           loaded: true
         )}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 5000)

    if socket.assigns[:param_error] do
      {:noreply, socket}
    else
      {:noreply, reload(socket)}
    end
  end

  defp reload(socket) do
    filters = socket.assigns.filters

    result =
      cond do
        socket.assigns.live_action == :entry and filters["id"] in [nil, ""] ->
          {:ok, nil}

        socket.assigns.live_action == :entry ->
          Context.show(filters["id"])

        filters["repo"] in [nil, ""] ->
          {:ok, nil}

        filters["q"] not in [nil, ""] ->
          Context.search(Map.drop(filters, ~w(id cursor)) |> Map.put("limit", "100"))

        true ->
          Context.recent(Map.drop(filters, ~w(id q)) |> Map.put("limit", "50"))
      end

    case result do
      {:ok, data} -> assign(socket, data: data, error: nil, loaded: true)
      {:error, _code, message} -> assign(socket, data: nil, error: message, loaded: true)
    end
  end

  defp next_path(filters, cursor),
    do: "/context?" <> URI.encode_query(Map.put(filters, "cursor", cursor))

  defp load_repos do
    case Context.repos() do
      {:ok, repos} -> repos
      {:error, _, _} -> []
    end
  end

  @doc """
  Maps the repository dropdown selection to an effective `repo` param.

  The dropdown submits `repo=<known>` directly, or `repo=other` together
  with `repo_other=<typed>`. Returns `{:ok, params}` with the resolved
  `repo` (or no `repo` key when nothing usable was chosen) and without
  `repo_other`, or `{:error, message}` when a selected repository and a
  different typed repository disagree.
  """
  def resolve_repo(params) when is_map(params) do
    other = params |> Map.get("repo_other", "") |> to_string() |> String.trim()
    cleaned = Map.delete(params, "repo_other")
    trimmed_repo = cleaned |> Map.get("repo") |> to_string() |> String.trim()

    cond do
      other == "" ->
        if trimmed_repo in ["", "other"],
          do: {:ok, Map.delete(cleaned, "repo")},
          else: {:ok, cleaned}

      trimmed_repo in ["", "other"] ->
        {:ok, Map.put(cleaned, "repo", other)}

      trimmed_repo == other ->
        {:ok, Map.put(cleaned, "repo", other)}

      true ->
        {:error, "Repository and Other repository disagree; clear one."}
    end
  end

  @doc """
  Builds dropdown options from known repos plus the current selection.

  Each option is `%{value:, label:, selected:}`. Known repos render as
  `owner/name (N entries)` in alpha order; a current selection outside the
  known list (typed repo or entry-page link) is prepended so the control
  still reflects it; `"other"` stays available for first-time repos.
  """
  def repo_options(repos, selected) when is_list(repos) do
    known = Enum.map(repos, & &1.repo)

    options =
      Enum.map(repos, fn %{repo: repo, entries: count} ->
        %{value: repo, label: "#{repo} (#{count} #{entry_word(count)})", selected: repo == selected}
      end)

    options =
      if selected not in [nil, "", "other"] and selected not in known do
        [%{value: selected, label: selected, selected: true} | options]
      else
        options
      end

    options ++ [%{value: "other", label: "Other (type below)…", selected: selected == "other"}]
  end

  defp entry_word(1), do: "entry"
  defp entry_word(_), do: "entries"

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <div class="page-title"><h1>Shared context</h1><p>Attributed findings, evidence and corrections</p></div>
      <p class="notice">Entries are worker assertions. Evidence links and relationships are retained; the server does not certify their conclusions. Reads do not acknowledge an agent's feed.</p>
      <p :if={!@loaded}>Loading shared context…</p>
      <p :if={@error} class="notice danger" role="alert">{@error}</p>
      <p :if={@param_error} class="notice danger" role="alert">{@param_error}</p>
      <div :if={@live_action == :index}>
        <form action="/context" method="get" class="filters">
          <label>Repository
            <select name="repo" required>
              <option value="">Choose a repository…</option>
              <option
                :for={opt <- repo_options(@repos, @filters["repo"])}
                value={opt.value}
                selected={opt.selected}
              >{opt.label}</option>
            </select>
          </label>
          <label>Other repository<input name="repo_other" placeholder="owner/repository" /></label>
          <label>Search<input name="q" value={@filters["q"]} placeholder="Failure signature or finding" maxlength="512" /></label>
          <label>Task<input name="task" value={@filters["task"]} /></label>
          <label>Kind<input name="kind" value={@filters["kind"]} placeholder="OBSERVED, FACT, FAIL…" /></label>
          <button type="submit">Find context</button>
        </form>
        <p :if={@loaded && !@data && !@error && !@param_error}>Choose a repository to browse its latest findings or search with BM25.</p>
        <div :if={@data}>
          <p :if={@data[:backend]} class="context">Ranked with {@data.backend}; at most 100 results. Refine the query for a smaller result set.</p>
          <p :if={@data.entries == []}>No matching findings.</p>
          <article :for={entry <- @data.entries} class="task-detail context-entry">
            <span class="flag">{entry.kind}</span>
            <h2><a href={"/context/#{entry.id}"}>{entry.summary}</a></h2>
            <p class="attribution">{entry.source_agent_id} · {entry.model} · {entry.harness} · {entry.created_at}</p>
            <p :if={entry[:score]}>BM25 score: {Float.round(entry.score, 4)}</p>
            <p :if={entry.task_id}>Task: <a href={"/tasks/#{entry.task_id}"}>{entry.task_id}</a></p>
          </article>
          <a :if={@data[:next_cursor]} class="more" href={next_path(@filters, @data.next_cursor)}>Older findings</a>
        </div>
      </div>
      <article :if={@live_action == :entry && @data} class="task-detail">
        <span class="flag">{@data.entry.kind}</span>
        <h2>{@data.entry.summary}</h2>
        <p class="attribution">{@data.entry.source_agent_id} · {@data.entry.model} · {@data.entry.harness} · {@data.entry.created_at}</p>
        <dl><dt>Repository</dt><dd><a href={"/context?" <> URI.encode_query(%{"repo" => @data.entry.repo})}>{@data.entry.repo}</a></dd><dt>Publication key</dt><dd>{@data.entry.entry_key}</dd><dt :if={@data.entry.source_revision}>Source commit</dt><dd :if={@data.entry.source_revision}>{@data.entry.source_revision}</dd></dl>
        <p :if={@data.entry.task_id}>Task: <a href={"/tasks/#{@data.entry.task_id}"}>{@data.entry.task_id}</a></p>
        <p :if={@data.entry.pr_url}><a href={@data.entry.pr_url} rel="noopener noreferrer">Pull request</a></p>
        <pre class="description">{@data.entry.detail}</pre>
        <h3>Evidence</h3>
        <ul><li :for={url <- @data.entry.evidence_urls}><a href={url} rel="noopener noreferrer">{url}</a></li></ul>
        <h3>Directed relationships</h3>
        <p :if={@data.links_more} class="notice warning">Showing the first 100 relationships; more are retained.</p>
        <p :if={@data.links == []}>No retained relationships.</p>
        <ul><li :for={link <- @data.links}><a href={"/context/#{link.entry_id}"}>Entry {link.entry_id}</a> {link.relation} <a href={"/context/#{link.target_id}"}>entry {link.target_id}</a></li></ul>
      </article>
    </main>
    """
  end
end

