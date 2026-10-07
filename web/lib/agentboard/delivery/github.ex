defmodule Agentboard.Delivery.Github do
  @moduledoc "Bounded complete head-check collection; repository policies and merge-ref verdicts are a later gate."
  alias Agentboard.Delivery.GithubHTTP

  @max_requests 32
  @max_pages 10
  @max_attempts 500
  @failures ~w(failure error timed_out cancelled action_required startup_failure)

  def collect(pr) do
    ctx = %{deadline: System.monotonic_time(:millisecond) + 90_000, requests: 0}

    with {:ok, root} <- root(pr),
         {:ok, before, ctx} <- metadata(root, pr, ctx),
         {:ok, suites, ctx} <-
           pages(root <> "/commits/" <> before.head_sha <> "/check-suites", "check_suites", ctx),
         {:ok, runs, ctx} <- suite_runs(root, before.head_sha, suites, ctx),
         {:ok, statuses, ctx} <-
           pages(root <> "/commits/" <> before.head_sha <> "/statuses", nil, ctx),
         {:ok, attempts} <- normalize(runs, statuses, before.head_sha),
         {:ok, after_read, _ctx} <- metadata(root, pr, ctx),
         true <- before == after_read do
      # A clean set is not policy-verified green. No expected checks, required
      # rules, merge/test-ref association or BuildBuddy correlation are inferred.
      state =
        cond do
          Enum.any?(attempts, &(&1.latest and &1.conclusion in @failures)) -> "failing"
          Enum.any?(attempts, &(&1.latest and &1.status != "completed")) -> "pending"
          true -> "unknown"
        end

      {:ok,
       Map.merge(before, %{
         ci_state: state,
         payload: %{
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
      {:ok, %{head_sha: head, base_sha: base, lifecycle: if(merged, do: "merged", else: state)},
       ctx}
    else
      {:error, _, _} = error -> error
      _ -> {:error, "incomplete", 60}
    end
  end

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
      case GithubHTTP.get(path, remaining) do
        {:ok, data, headers} -> {:ok, data, headers, %{ctx | requests: ctx.requests + 1}}
        {:error, _, _} = error -> error
      end
    else
      {:error, "incomplete", 60}
    end
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

  defp text?(name),
    do:
      is_binary(name) and byte_size(name) in 1..256 and String.valid?(name) and
        not String.contains?(name, ["\0", "\r", "\n"]) and not contains_token?(name)

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

