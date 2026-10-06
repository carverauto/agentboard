defmodule AgentboardWeb.ContextLive do
  use Phoenix.LiveView, layout: false
  alias Agentboard.Context

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 5000)
    {:ok, assign(socket, filters: %{}, data: nil, error: nil, loaded: false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      params
      |> Map.take(~w(id repo task kind q cursor))
      |> Map.reject(fn {_key, value} -> value == "" end)

    socket = assign(socket, filters: filters)
    {:noreply, if(connected?(socket), do: reload(socket), else: socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 5000)
    {:noreply, reload(socket)}
  end

  defp reload(socket) do
    filters = socket.assigns.filters

    result =
      cond do
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

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <div class="page-title"><h1>Shared context</h1><p>Attributed findings, evidence and corrections</p></div>
      <p class="notice">Entries are worker assertions. Evidence links and relationships are retained; the server does not certify their conclusions. Reads do not acknowledge an agent's feed.</p>
      <p :if={!@loaded}>Loading shared context…</p>
      <p :if={@error} class="notice danger" role="alert">{@error}</p>
      <div :if={@live_action == :index}>
        <form action="/context" method="get" class="filters">
          <label>Repository<input name="repo" value={@filters["repo"]} placeholder="owner/repository" required /></label>
          <label>Search<input name="q" value={@filters["q"]} placeholder="Failure signature or finding" maxlength="512" /></label>
          <label>Task<input name="task" value={@filters["task"]} /></label>
          <label>Kind<input name="kind" value={@filters["kind"]} placeholder="OBSERVED, FACT, FAIL…" /></label>
          <button type="submit">Find context</button>
        </form>
        <p :if={@loaded && !@data && !@error}>Choose a repository to browse its latest findings or search with BM25.</p>
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

