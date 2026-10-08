defmodule Agentboard.Delivery.Github do
  @moduledoc "Bounded complete head-check collection; repository policies and merge-ref verdicts are a later gate."
  alias Agentboard.Delivery.{GithubHTTP, ProviderAdmission}

  @max_requests 32
  @max_pages 10
  @max_attempts 500
  @failures ~w(failure error timed_out cancelled action_required startup_failure)

  def collect(pr) do
    with {:ok, %{allowed: true, credit: credit}} <-
           ProviderAdmission.reserve_poll(pr, @max_requests) do
      cache = Map.get(pr, :github_cache, %{})
      scope = cache_scope()
      responses = if cache["scope"] == scope, do: cache["responses"] || %{}, else: %{}

      ctx = %{
        deadline: System.monotonic_time(:millisecond) + 90_000,
        requests: 0,
        credit: credit,
        cache: responses,
        saved: %{},
        scope: scope
      }

      try do
        with {:ok, root} <- root(pr),
             {:ok, before, ctx} <- metadata(root, pr, ctx),
             {:ok, result} <- collect_head(root, pr, before, ctx) do
          {:ok, result}
        else
          false -> {:error, "incomplete", 60}
          {:error, reason, seconds} -> {:error, reason, seconds}
          {:error, reason} -> {:error, reason, 60}
        end
      after
        # Durable consumption occurs before each TLS request. This refunds only
        # unused credit; expiry recovery does the same after a killed worker.
        ProviderAdmission.release(credit)
      end
    else
      {:ok, %{allowed: false, retry_after: seconds, reason: reason}} ->
        {:error, reason, seconds}

      {:error, reason, _} ->
        {:error, reason, 60}
    end
  end

  # A terminal lifecycle is a complete metadata observation, not CI evidence.
  # Avoid suites/runs/status requests after merge/close. Reconciliation only
  # re-enables closed rows hourly (or on a new explicit link) to detect reopen.
  defp collect_head(_root, _pr, %{lifecycle: lifecycle} = before, ctx)
       when lifecycle in ["merged", "closed"] do
    {:ok,
     Map.merge(before, %{
       ci_state: "unknown",
       github_cache: saved_cache(ctx),
       payload: %{
         "draft" => before.draft,
         "mergeable" => before.mergeable,
         "mergeable_state" => before.mergeable_state,
         "base_ref" => before.base_ref,
         "head_ref" => before.head_ref,
         "head_repo" => before.head_repo,
         "coverage" => "terminal_metadata",
         "policy" => "unknown",
         "tested_ref" => "head",
         "attempts" => [],
         "evidence" => "source_links_only"
       }
     })}
  end

  defp collect_head(root, pr, before, ctx) do
    with {:ok, suites, ctx} <-
           pages(root <> "/commits/" <> before.head_sha <> "/check-suites", "check_suites", ctx),
         {:ok, runs, ctx} <- suite_runs(root, before.head_sha, suites, ctx),
         {:ok, statuses, ctx} <-
           pages(root <> "/commits/" <> before.head_sha <> "/statuses", nil, ctx),
         {:ok, attempts} <- normalize(runs, statuses, before.head_sha),
         {:ok, after_read, ctx} <- metadata(root, pr, ctx),
         true <- revision(before) == revision(after_read) do
      # A clean set is not policy-verified green. No expected checks, required
      # rules, merge/test-ref association or BuildBuddy correlation are inferred.
      state =
        cond do
          Enum.any?(attempts, &(&1.latest and &1.conclusion in @failures)) -> "failing"
          Enum.any?(attempts, &(&1.latest and &1.status != "completed")) -> "pending"
          true -> "unknown"
        end

      {:ok,
       Map.merge(after_read, %{
         ci_state: state,
         github_cache: saved_cache(ctx),
         payload: %{
           "draft" => after_read.draft,
           "mergeable" => after_read.mergeable,
           "mergeable_state" => after_read.mergeable_state,
           "base_ref" => after_read.base_ref,
           "head_ref" => after_read.head_ref,
           "head_repo" => after_read.head_repo,
           "coverage" => "complete_head",
           "policy" => "unknown",
           "tested_ref" => "head",
           "attempts" => attempts,
           "evidence" => "source_links_only"
         }
       })}
    else
      false -> {:error, "incomplete", 60}
      {:error, reason, seconds} -> {:error, reason, seconds}
      {:error, reason} -> {:error, reason, 60}
    end
  end

  # Same admitted HTTPS transport as PR collection; never follow a provider URL.
  def branch(owner, repo, ref) do
    with true <- ref?(ref),
         {:ok, root} <- root(%{owner: owner, repo: repo, number: "1"}),
         {:ok, %{"name" => ^ref, "commit" => %{"sha" => sha}}, _} <-
           GithubHTTP.get(
             root <> "/branches/" <> URI.encode(ref, &URI.char_unreserved?/1),
             10_000
           ),
         true <- sha?(sha) do
      {:ok, sha}
    else
      {:error, _, _} = error -> error
      _ -> {:error, "incomplete", 60}
    end
  end

  defp revision(metadata),
    do:
      Map.take(metadata, [
        :head_sha,
        :base_sha,
        :base_ref,
        :head_ref,
        :head_repo,
        :lifecycle,
        :draft
      ])

  defp bounded_state(value)
       when value in ~w(clean dirty unstable behind blocked unknown draft has_hooks), do: value

  defp bounded_state(_), do: nil

  defp ref?(ref),
    do:
      is_binary(ref) and byte_size(ref) in 1..255 and
        not String.contains?(ref, ["\u0000", "\n", "\r"])

  defp root(pr) do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, pr.owner) and
         Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, pr.repo) and
         Regex.match?(~r/\A[1-9][0-9]*\z/, pr.number),
       do: {:ok, "/repos/" <> pr.owner <> "/" <> pr.repo},
       else: {:error, "incomplete"}
  end

  defp metadata(root, pr, ctx) do
    with {:ok, data, _headers, ctx} <- request(root <> "/pulls/" <> pr.number, ctx),
         %{
           "head" => %{"sha" => head},
           "base" => %{"sha" => base},
           "state" => state,
           "merged" => merged,
           "number" => number
         } <- data,
         true <-
           sha?(head) and sha?(base) and state in ["open", "closed"] and
             is_boolean(merged) and is_integer(number) and Integer.to_string(number) == pr.number do
      {:ok,
       %{
         head_sha: head,
         base_sha: base,
         lifecycle: if(merged, do: "merged", else: state),
         draft: if(is_boolean(data["draft"]), do: data["draft"], else: nil),
         mergeable: if(is_boolean(data["mergeable"]), do: data["mergeable"], else: nil),
         mergeable_state: bounded_state(data["mergeable_state"]),
         base_ref: if(ref?(data["base"]["ref"]), do: data["base"]["ref"]),
         head_ref:
           if(ref?(data["head"]["ref"]) and not contains_token?(data["head"]["ref"]),
             do: data["head"]["ref"]
           ),
         head_repo: head_repository(data["head"]["repo"])
       }, ctx}
    else
      {:error, _, _} = error -> error
      _ -> {:error, "incomplete", 60}
    end
  end

  defp head_repository(%{"full_name" => name}) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, name) and not contains_token?(name),
      do: String.downcase(name)
  end

  defp head_repository(_), do: nil

  defp suite_runs(root, sha, suites, ctx) do
    Enum.reduce_while(suites, {:ok, [], ctx}, fn suite, {:ok, acc, ctx} ->
      case suite do
        %{"id" => id, "head_sha" => ^sha} when is_integer(id) and id > 0 ->
          case pages(
                 root <> "/check-suites/" <> Integer.to_string(id) <> "/check-runs",
                 "check_runs",
                 ctx
               ) do
            {:ok, runs, ctx} when length(acc) + length(runs) <= @max_attempts ->
              {:cont, {:ok, acc ++ runs, ctx}}

            {:error, _, _} = error ->
              {:halt, error}

            _ ->
              {:halt, {:error, "incomplete", 60}}
          end

        _ ->
          {:halt, {:error, "incomplete", 60}}
      end
    end)
  end

  defp pages(path, key, ctx), do: page(path, key, ctx, 1, [], nil)

  defp page(_path, _key, _ctx, page, _acc, _total) when page > @max_pages,
    do: {:error, "incomplete", 60}

  defp page(path, key, ctx, page, acc, total) do
    filter = if key == "check_runs", do: "&filter=all", else: ""
    route = path <> "?per_page=100&page=" <> Integer.to_string(page) <> filter

    with {:ok, body, headers, ctx} <- request(route, ctx),
         {:ok, items, count} <- page_items(body, key),
         true <- length(items) <= 100 and length(acc) + length(items) <= @max_attempts,
         true <- is_nil(total) or count == total,
         true <- safe_next?(headers["link"], path, page + 1, key) do
      acc = acc ++ items
      count = total || count

      more? =
        if key,
          do: length(acc) < count,
          else: next?(headers["link"]) or length(items) == 100

      cond do
        more? and items == [] -> {:error, "incomplete", 60}
        more? -> page(path, key, ctx, page + 1, acc, count)
        key && (length(acc) != count or next?(headers["link"])) -> {:error, "incomplete", 60}
        duplicate_ids?(acc) -> {:error, "incomplete", 60}
        true -> {:ok, acc, ctx}
      end
    else
      {:error, _, _} = error -> error
      _ -> {:error, "incomplete", 60}
    end
  end

  defp page_items(body, nil) when is_list(body), do: {:ok, body, nil}

  defp page_items(%{"total_count" => total} = body, key) when is_integer(total) and total >= 0 do
    case body[key] do
      items when is_list(items) -> {:ok, items, total}
      _ -> {:error, "incomplete", 60}
    end
  end

  defp page_items(_, _), do: {:error, "incomplete", 60}

  defp request(path, ctx) do
    remaining = ctx.deadline - System.monotonic_time(:millisecond)

    if remaining > 0 and ctx.requests < @max_requests do
      cached = ctx.cache[path]
      conditional = conditional_headers(cached)
      result = GithubHTTP.get(path, remaining, credit: ctx.credit, conditional: conditional)

      case result do
        {:ok, data, headers} ->
          {:ok, data, headers, cache_response(path, data, headers, ctx)}

        {:not_modified, headers, charged_window} when is_map(cached) ->
          with {:ok, :ok} <- ProviderAdmission.not_modified(ctx.credit, charged_window) do
            # Keep the cached pagination Link; a 304 need not repeat it.
            headers =
              Map.merge(cached["headers"], Map.take(headers, ["etag", "last-modified", "link"]))

            {:ok, cached["data"], headers, cache_response(path, cached["data"], headers, ctx)}
          else
            _ -> {:error, "incomplete", 60}
          end

        {:not_modified, _, _} ->
          {:error, "incomplete", 60}

        {:error, _, _} = error ->
          error
      end
    else
      {:error, "incomplete", 60}
    end
  end

  defp cache_scope do
    config = Application.get_env(:agentboard, :github, [])

    :crypto.hash(
      :sha256,
      (config[:api_url] || "https://api.github.com") <> "\0" <> (config[:token] || "")
    )
    |> Base.encode16(case: :lower)
  end

  defp conditional_headers(%{"headers" => headers}) do
    cond do
      safe_validator?(headers["etag"]) ->
        [{"if-none-match", headers["etag"]}]

      safe_validator?(headers["last-modified"]) ->
        [{"if-modified-since", headers["last-modified"]}]

      true ->
        []
    end
  end

  defp conditional_headers(_), do: []

  defp safe_validator?(value), do: bounded_text?(value, 512)

  defp cache_response(path, data, headers, ctx) do
    entry = %{"data" => data, "headers" => Map.take(headers, ["etag", "last-modified", "link"])}
    encoded = Jason.encode!(entry)

    saved =
      if conditional_headers(entry) != [] and byte_size(encoded) <= 65_536 and
           cache_safe?(entry),
         do: Map.put(ctx.saved, path, entry),
         else: ctx.saved

    %{ctx | saved: saved, requests: ctx.requests + 1}
  end

  defp cache_safe?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, "\0") and not contains_token?(value)

  defp cache_safe?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> cache_safe?(k) and cache_safe?(v) end)

  defp cache_safe?(value) when is_list(value), do: Enum.all?(value, &cache_safe?/1)
  defp cache_safe?(_), do: true

  defp saved_cache(ctx) do
    # Only routes sampled by this complete poll survive a changed head.
    if byte_size(Jason.encode!(ctx.saved)) <= 524_288,
      do: %{"scope" => ctx.scope, "responses" => ctx.saved},
      else: %{}
  end

  defp next?(link), do: is_binary(link) and Regex.match?(~r/rel="next"/, link)

  defp safe_next?(link, path, next_page, key) do
    # Link URLs are validation evidence only; construct subsequent URLs locally.
    # Even an apparently same-origin URL never supplies credentials/destination.
    case if(is_binary(link), do: Regex.run(~r/<([^>]+)>;\s*rel="next"/, link)) do
      nil ->
        not next?(link)

      [_, url] ->
        expected =
          URI.parse(
            Application.get_env(:agentboard, :github, [])[:api_url] || "https://api.github.com"
          )

        parsed = URI.parse(url)
        params = URI.decode_query(parsed.query || "")

        parsed.scheme == expected.scheme and parsed.host == expected.host and
          parsed.port == expected.port and
          is_nil(parsed.userinfo) and is_nil(parsed.fragment) and
          same_endpoint?(parsed.path, path) and query_contract?(params, key, next_page)
    end
  rescue
    ArgumentError -> false
  end

  defp same_endpoint?(link_path, "/repos/" <> rest = request_path) when is_binary(link_path) do
    case String.split(rest, "/", parts: 3) do
      [owner, repo, tail] when owner != "" and repo != "" and tail != "" ->
        suffix = "/" <> tail

        link_path == request_path or canonical_repository?(link_path, suffix) or
          status_alias?(link_path, suffix)

      _ ->
        false
    end
  end

  defp same_endpoint?(_, _), do: false

  defp status_alias?("/repositories/" <> rest, "/commits/" <> commit_tail) do
    case String.split(rest, "/", parts: 2) do
      [id, "statuses/" <> sha] ->
        decimal_id?(id) and commit_tail == sha <> "/statuses"

      _ ->
        false
    end
  end

  defp status_alias?(_, _), do: false

  defp canonical_repository?("/repositories/" <> rest, suffix) do
    case String.split(rest, "/", parts: 2) do
      [id, tail] -> decimal_id?(id) and "/" <> tail == suffix
      _ -> false
    end
  end

  defp canonical_repository?(_, _), do: false

  defp decimal_id?(id), do: Regex.match?(~r/\A[1-9][0-9]*\z/, id)

  defp query_contract?(params, "check_runs", next_page) do
    params == %{"filter" => "all", "page" => Integer.to_string(next_page), "per_page" => "100"}
  end

  defp query_contract?(params, _key, next_page) do
    params == %{"page" => Integer.to_string(next_page), "per_page" => "100"}
  end

  defp duplicate_ids?(items) do
    ids = Enum.map(items, &if(is_map(&1), do: &1["id"]))
    Enum.any?(ids, &is_nil/1) or length(Enum.uniq(ids)) != length(ids)
  end

  defp normalize(runs, statuses, sha) when length(runs) + length(statuses) <= @max_attempts do
    entries = Enum.map(runs, &run(&1, sha)) ++ Enum.map(statuses, &status/1)

    if duplicate_ids?(runs) or duplicate_ids?(statuses) or Enum.any?(entries, &is_nil/1) do
      {:error, "incomplete", 60}
    else
      # Provider IDs break equal-time ties and preserve a newly queued attempt
      # with no started_at. completed_at never decides which attempt is newest.
      latest =
        entries
        |> Enum.group_by(& &1.identity)
        |> Map.new(fn {key, group} ->
          {key, Enum.max_by(group, & &1.provider_id).provider_id}
        end)

      entries =
        entries
        |> Enum.map(&Map.put(&1, :latest, latest[&1.identity] == &1.provider_id))
        |> Enum.sort_by(&{&1.identity, &1.provider_id})

      if byte_size(Jason.encode!(entries)) <= 240_000,
        do: {:ok, entries},
        else: {:error, "incomplete", 60}
    end
  end

  defp normalize(_, _, _), do: {:error, "incomplete", 60}

  defp run(
         %{
           "id" => id,
           "name" => name,
           "head_sha" => sha,
           "app" => %{"id" => app},
           "status" => state,
           "conclusion" => conclusion
         } = data,
         sha
       )
       when is_integer(id) and id > 0 and is_integer(app) and app > 0 and
              state in ["queued", "in_progress", "completed", "waiting", "pending", "requested"] do
    if text?(name) and
         (is_nil(conclusion) or
            conclusion in ~w(success neutral skipped stale failure timed_out cancelled action_required startup_failure)) and
         (state != "completed" or not is_nil(conclusion)) and
         timestamps?(data, ["started_at", "completed_at"]) do
      %{
        identity: "check:" <> Integer.to_string(app) <> ":" <> name,
        provider_id: id,
        kind: "check_run",
        name: name,
        status: state,
        conclusion: conclusion,
        started_at: data["started_at"],
        completed_at: data["completed_at"],
        source_url: source_url(data["html_url"]),
        details_url: source_url(data["details_url"])
      }
    end
  end

  defp run(_, _), do: nil

  defp status(%{"id" => id, "context" => name, "state" => state, "created_at" => time} = data)
       when is_integer(id) and id > 0 and state in ["success", "failure", "error", "pending"] do
    if text?(name) and valid_time?(time) do
      %{
        identity: "status:" <> name,
        provider_id: id,
        kind: "commit_status",
        name: name,
        status: if(state == "pending", do: "pending", else: "completed"),
        conclusion: state,
        started_at: time,
        completed_at: nil,
        source_url: source_url(data["target_url"]),
        details_url: nil
      }
    end
  end

  defp status(_), do: nil

  defp text?(name), do: bounded_text?(name, 256)

  defp bounded_text?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
        not String.contains?(value, ["\0", "\r", "\n"]) and not contains_token?(value)

  defp contains_token?(text) do
    token = Application.get_env(:agentboard, :github, [])[:token]
    is_binary(token) and token != "" and String.contains?(text, token)
  end

  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp timestamps?(data, fields),
    do: Enum.all?(fields, &(is_nil(data[&1]) or valid_time?(data[&1])))

  defp valid_time?(time) when is_binary(time),
    do: match?({:ok, _, _}, DateTime.from_iso8601(time))

  defp valid_time?(_), do: false

  defp source_url(value) when is_binary(value) and byte_size(value) <= 2048 do
    uri = URI.parse(value)

    if uri.scheme == "https" and uri.host in ["github.com", "carverauto.buildbuddy.io"] and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         not contains_token?(value),
       do: value
  end

  defp source_url(_), do: nil
end
