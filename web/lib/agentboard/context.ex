defmodule Agentboard.Context do
  use Ash.Domain, backwards_compatible_interface?: false
  require Ash.Query
  import Ash.Expr
  alias Agentboard.Context.{Entry, Link, Receipt}

  resources do
    resource(Entry)
    resource(Link)
    resource(Receipt)
  end

  @fields ~w(entry_key repo task_id pr_url source_revision kind summary detail evidence_urls links)
  @metadata ~w(id entry_key repo task_id pr_url source_revision kind summary evidence_urls source_agent_id model harness created_at)a
  @kinds ~w(OBSERVED FACT FAIL CLAIM PATCH_SUMMARY)
  @relations ~w(supports contradicts supersedes depends_on)
  @repo ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

  def publish(actor, data) do
    with {:ok, actor} <- matching_actor(actor),
         {:ok, data} <- publication(data) do
      digest =
        :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(data)))
        |> Base.encode16(case: :lower)

      attrs = data |> Map.delete("links") |> Map.put("digest", digest)

      result =
        Agentboard.Repo.transact(fn ->
          with {:ok, entry} <-
                 Entry |> Ash.Changeset.for_create(:publish, attrs, actor: actor) |> Ash.create(),
               :ok <- create_links(entry, data["links"], actor) do
            Agentboard.Cooperation.Runtime.capture_context(entry)
            {:ok, entry}
          end
        end)

      case result do
        {:ok, entry} ->
          {:ok, %{entry: record(entry), idempotent: false}}

        {:error, error} ->
          case existing(actor["agent"], data["entry_key"]) do
            {:ok, %{digest: ^digest} = entry} ->
              {:ok, %{entry: record(entry), idempotent: true}}

            {:ok, %{}} ->
              {:error, "conflict",
               "Entry key already has different content; append a correction with a new key"}

            {:ok, nil} ->
              failure(error)

            {:error, _} ->
              {:error, "unavailable", "Context storage unavailable"}
          end
      end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, "unavailable", "Context storage unavailable"}
  end

  def show(id) do
    with {:ok, id} <- positive(id),
         {:ok, entry} <-
           Entry
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.select(@metadata ++ [:detail])
           |> Ash.read_one(),
         false <- is_nil(entry),
         {:ok, links} <-
           Link
           |> Ash.Query.filter(entry_id == ^id or target_id == ^id)
           |> Ash.Query.limit(101)
           |> Ash.read() do
      {:ok,
       %{
         entry: Map.put(record(entry), :detail, entry.detail),
         links:
           Enum.take(links, 100) |> Enum.map(&Map.take(&1, [:entry_id, :target_id, :relation])),
         links_more: length(links) > 100
       }}
    else
      true -> {:error, "not_found", "Context entry not found"}
      {:error, _, _} = error -> error
      {:error, error} -> failure(error)
    end
  end

  def search(params) do
    with {:ok, filters} <- filters(params, ~w(repo task kind q limit)),
         true <- bounded_text?(params["q"], 512, true) do
      q = params["q"]

      query =
        scoped(filters)
        |> Ash.Query.filter(
          expr(
            fragment("to_tsvector('simple', ?) @@ plainto_tsquery('simple', ?)", search_text, ^q)
          )
        )
        |> Ash.Query.load(bm25_score: %{q: q})
        |> Ash.Query.sort(bm25_score: {%{q: q}, :asc}, id: :asc)
        |> Ash.Query.limit(filters.limit)

      case Ash.read(query, timeout: 5000) do
        {:ok, entries} ->
          {:ok,
           %{
             entries: Enum.map(entries, &Map.put(record(&1), :score, -&1.bm25_score)),
             backend: "pg_textsearch-1.5.1",
             limit: filters.limit
           }}

        {:error, error} ->
          failure(error)
      end
    else
      false -> {:error, "invalid_input", "Search requires a nonblank query of at most 512 bytes"}
      error -> error
    end
  end

  def recent(params) do
    with {:ok, filters} <- filters(params, ~w(repo task kind limit cursor)),
         {:ok, cursor} <- if(params["cursor"], do: positive(params["cursor"]), else: {:ok, nil}) do
      query = scoped(filters) |> Ash.Query.sort(id: :desc) |> Ash.Query.limit(filters.limit + 1)
      query = if cursor, do: Ash.Query.filter(query, id < ^cursor), else: query

      case Ash.read(query, timeout: 5000) do
        {:ok, entries} ->
          page = Enum.take(entries, filters.limit)

          {:ok,
           %{
             entries: Enum.map(page, &record/1),
             next_cursor: if(length(entries) > filters.limit, do: List.last(page).id, else: nil)
           }}

        {:error, error} ->
          failure(error)
      end
    end
  end

  def feed(actor, params) do
    with {:ok, actor} <- matching_actor(actor),
         {:ok, filters} <- filters(params, ~w(repo task kind limit)),
         {:ok, entries} <-
           scoped(filters)
           |> Ash.Query.filter(
             expr(
               fragment(
                 "? NOT IN (SELECT entry_id FROM context_receipts WHERE source_agent_id = ?)",
                 id,
                 ^actor["agent"]
               )
             )
           )
           |> Ash.Query.sort(id: :asc)
           |> Ash.Query.limit(filters.limit + 1)
           |> Ash.read(timeout: 5000) do
      {:ok,
       %{
         entries: Enum.take(entries, filters.limit) |> Enum.map(&record/1),
         more: length(entries) > filters.limit
       }}
    else
      {:error, _, _} = error -> error
      {:error, error} -> failure(error)
    end
  end

  def acknowledge(actor, id) do
    with {:ok, actor} <- matching_actor(actor),
         {:ok, id} <- positive(id),
         {:ok, entry} <- Ash.get(Entry, id, not_found_error?: false),
         false <- is_nil(entry) do
      Agentboard.Board.Operations.transaction(fn ->
        <<key::signed-64, _::binary>> =
          :crypto.hash(:sha256, "agentboard-context-receipt:#{actor["agent"]}:#{id}")

        Agentboard.Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])

        existing =
          Ash.get!(Receipt, %{entry_id: id, source_agent_id: actor["agent"]},
            not_found_error?: false
          )

        unless existing,
          do:
            Receipt
            |> Ash.Changeset.for_create(:acknowledge, %{entry_id: id}, actor: actor)
            |> Ash.create!()

        %{acknowledged: id}
      end)
    else
      true -> {:error, "not_found", "Context entry not found"}
      {:error, _, _} = error -> error
      {:error, error} -> failure(error)
    end
  end

  defp matching_actor(actor) do
    with {:ok, actor} <- Agentboard.Input.actor(actor),
         {:ok, %{harness: harness}} <- Ash.get(Agentboard.Board.Resources.Agent, actor["agent"]),
         true <- harness == actor["harness"] do
      {:ok, actor}
    else
      _ -> {:error, "invalid_context", "Register a matching agent, model and harness first"}
    end
  end

  defp publication(data) when is_map(data) do
    data = Map.merge(%{"detail" => "", "evidence_urls" => [], "links" => []}, data)

    valid =
      Enum.all?(Map.keys(data), &(&1 in @fields)) and Agentboard.Input.slug?(data["entry_key"]) and
        repo?(data["repo"]) and data["kind"] in @kinds and
        bounded_text?(data["summary"], 600, true) and bounded_text?(data["detail"], 16384, false) and
        optional?(data["task_id"], &Agentboard.Input.slug?/1) and
        optional?(
          data["pr_url"],
          &(is_binary(&1) and
              Regex.match?(
                ~r/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*$/,
                &1
              ))
        ) and
        optional?(
          data["source_revision"],
          &(is_binary(&1) and Regex.match?(~r/^[a-f0-9]{40}$/, &1))
        ) and valid_urls?(data["evidence_urls"]) and valid_links?(data["links"])

    if valid,
      do: {:ok, data},
      else: {:error, "invalid_input", "Invalid context publication or exceeded content limits"}
  end

  defp publication(_), do: {:error, "invalid_input", "Context publication must be an object"}
  defp optional?(nil, _), do: true
  defp optional?(value, fun), do: fun.(value)
  defp repo?(repo), do: is_binary(repo) and byte_size(repo) <= 256 and Regex.match?(@repo, repo)

  defp bounded_text?(text, max, nonblank),
    do:
      is_binary(text) and String.valid?(text) and byte_size(text) <= max and
        not String.contains?(text, <<0>>) and (not nonblank or String.trim(text) != "")

  defp valid_urls?(urls) when is_list(urls) and length(urls) <= 20 do
    Enum.all?(urls, fn url ->
      if bounded_text?(url, 2048, true) do
        uri = URI.parse(url)
        uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo)
      else
        false
      end
    end)
  end

  defp valid_urls?(_), do: false

  defp valid_links?(links) when is_list(links) and length(links) <= 20 do
    Enum.all?(links, fn
      %{"target_id" => id, "relation" => relation} = link ->
        map_size(link) == 2 and is_integer(id) and id > 0 and relation in @relations

      _ ->
        false
    end) and length(Enum.uniq(links)) == length(links)
  end

  defp valid_links?(_), do: false

  defp create_links(entry, links, actor) do
    Enum.reduce_while(links, :ok, fn link, :ok ->
      with {:ok, %{repo: repo}} <- Ash.get(Entry, link["target_id"]),
           true <- repo == entry.repo,
           {:ok, _} <-
             Link
             |> Ash.Changeset.for_create(
               :publish,
               %{entry_id: entry.id, target_id: link["target_id"], relation: link["relation"]},
               actor: actor
             )
             |> Ash.create() do
        {:cont, :ok}
      else
        _ ->
          {:halt,
           {:error,
            {"invalid_input", "Context links require existing entries in the same repository"}}}
      end
    end)
  end

  defp existing(agent, key),
    do:
      Entry
      |> Ash.Query.filter(source_agent_id == ^agent and entry_key == ^key)
      |> Ash.Query.select(@metadata ++ [:digest])
      |> Ash.read_one()

  defp scoped(filters) do
    query = Entry |> Ash.Query.select(@metadata) |> Ash.Query.filter(repo == ^filters.repo)
    query = if filters.task, do: Ash.Query.filter(query, task_id == ^filters.task), else: query
    if filters.kind, do: Ash.Query.filter(query, kind == ^filters.kind), else: query
  end

  defp filters(params, allowed) do
    limit = params["limit"] || "50"

    with true <- Enum.all?(Map.keys(params), &(&1 in allowed)),
         true <- repo?(params["repo"]),
         true <- optional?(params["task"], &Agentboard.Input.slug?/1),
         true <- optional?(params["kind"], &(&1 in @kinds)),
         {limit, ""} when limit in 1..100 <- Integer.parse(to_string(limit)) do
      {:ok, %{repo: params["repo"], task: params["task"], kind: params["kind"], limit: limit}}
    else
      _ -> {:error, "invalid_input", "Provide repo owner/name, valid filters and limit 1–100"}
    end
  end

  defp positive(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp positive(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "invalid_input", "Entry ID must be positive"}
    end
  end

  defp positive(_), do: {:error, "invalid_input", "Entry ID must be positive"}
  defp record(entry), do: Map.take(entry, @metadata)
  defp failure({code, message}), do: {:error, code, message}

  defp failure(%Ash.Error.Invalid{}),
    do: {:error, "invalid_input", "Invalid context record or reference"}

  defp failure(_), do: {:error, "unavailable", "Context storage unavailable"}
end
