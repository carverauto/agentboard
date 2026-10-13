defmodule Agentboard.Intake.Github do
  @moduledoc """
  The only two GitHub calls the intake credential makes: create an issue and
  list a repository's recent issues to find an intake marker. Both are
  confined to the configured intake repositories by the caller, run outside
  any database transaction and share the operator-pinned transport.

  Results are classified for the outbox:

    * `{:ok, value}` - the call succeeded;
    * `{:retry, reason, seconds}` - transient (outage, rate limit, lost
      response); the intent stays pending and searches before re-creating;
    * `{:rejected, reason}` - definitive refusal (validation, permission,
      missing repository); the intent parks as uncertain.
  """
  alias Agentboard.Delivery.GithubHTTP

  @user_agent {"user-agent", "agentboard-intake"}
  @timeout 15_000
  @page_size 100
  @max_pages 10

  def configured?, do: match?({:ok, _}, destination())

  def marker(item_id), do: "<!-- agentboard-intake:#{item_id} -->"

  def create_issue(repository, title, body, labels) do
    payload = Jason.encode!(%{"title" => title, "body" => body, "labels" => labels})
    headers = [@user_agent, {"content-type", "application/json"}]

    with {:ok, destination} <- destination() do
      case GithubHTTP.exchange(
             destination,
             "POST",
             "/repos/" <> repository <> "/issues",
             headers,
             payload,
             @timeout
           ) do
        {:ok, 201, _headers, body} ->
          case Jason.decode(body) do
            {:ok, %{"number" => number, "html_url" => url}}
            when is_integer(number) and is_binary(url) ->
              {:ok, %{number: number, url: url}}

            _ ->
              {:retry, "response_unreadable", 60}
          end

        {:ok, status, headers, body} ->
          classify(status, headers, body)

        {:error, :connect} ->
          {:retry, "unreachable", 60}

        {:error, _} ->
          {:retry, "response_lost", 60}
      end
    end
  end

  # Lists issues updated since `since` (oldest first) and returns those whose
  # body carries the marker. The list endpoint reads current state, unlike the
  # search index, so a just-created issue is visible. Pull requests are
  # skipped. An unfinished scan is transient, never proof of absence.
  def find_marker(repository, marker, since) do
    with {:ok, destination} <- destination() do
      scan(destination, repository, marker, DateTime.to_iso8601(since), 1, [])
    end
  end

  defp scan(_destination, _repository, _marker, _since, page, _found) when page > @max_pages,
    do: {:retry, "marker_search_incomplete", 300}

  defp scan(destination, repository, marker, since, page, found) do
    query =
      URI.encode_query(%{
        "state" => "all",
        "since" => since,
        "sort" => "created",
        "direction" => "asc",
        "per_page" => @page_size,
        "page" => page
      })

    case GithubHTTP.exchange(
           destination,
           "GET",
           "/repos/" <> repository <> "/issues?" <> query,
           [@user_agent],
           nil,
           @timeout
         ) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, issues} when is_list(issues) ->
            found = found ++ Enum.filter(issues, &marked?(&1, marker))

            if length(issues) < @page_size,
              do: {:ok, Enum.map(found, &%{number: &1["number"], url: &1["html_url"]})},
              else: scan(destination, repository, marker, since, page + 1, found)

          _ ->
            {:retry, "search_unreadable", 60}
        end

      {:ok, status, headers, body} ->
        case classify(status, headers, body) do
          {:rejected, reason} -> {:rejected, "search_" <> reason}
          {:retry, reason, seconds} -> {:retry, "search_" <> reason, seconds}
        end

      {:error, _} ->
        {:retry, "search_unavailable", 60}
    end
  end

  defp marked?(%{"body" => body, "number" => number, "html_url" => url} = issue, marker)
       when is_binary(body) and is_integer(number) and is_binary(url),
       do: not Map.has_key?(issue, "pull_request") and String.contains?(body, marker)

  defp marked?(_, _), do: false

  defp classify(status, headers, body) do
    cond do
      rate_limited?(status, headers, body) -> {:retry, "rate_limited", retry_seconds(headers)}
      status in [401, 403, 404, 410, 422] -> {:rejected, "rejected:#{status}"}
      true -> {:retry, "provider_status:#{status}", 60}
    end
  end

  defp rate_limited?(429, _headers, _body), do: true

  defp rate_limited?(403, headers, body) do
    is_binary(headers["retry-after"]) or headers["x-ratelimit-remaining"] == "0" or
      case Jason.decode(body) do
        {:ok, %{"message" => message}} when is_binary(message) ->
          String.contains?(String.downcase(message), ["rate limit", "abuse detection"])

        _ ->
          false
      end
  end

  defp rate_limited?(_, _, _), do: false

  defp retry_seconds(headers) do
    reset = integer(headers["x-ratelimit-reset"]) - System.system_time(:second)
    min(3_600, max(60, max(integer(headers["retry-after"]), reset)))
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp integer(_), do: 0

  # The intake credential is separate from the read-only CI observer token.
  # A file-backed token is re-read per use, so rotation needs no restart.
  defp destination do
    config = Application.get_env(:agentboard, :intake_github, [])

    token =
      case config[:token_file] do
        file when is_binary(file) and file != "" ->
          case File.read(file) do
            {:ok, contents} -> String.trim(contents)
            _ -> nil
          end

        _ ->
          config[:token]
      end

    case GithubHTTP.destination(Keyword.put(config, :token, token)) do
      {:ok, destination} -> {:ok, destination}
      {:error, _} -> {:retry, "github_unconfigured", 300}
    end
  end
end
