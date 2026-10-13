defmodule Agentboard.Intake.Import do
  @moduledoc """
  Reads the GitHub issues an import selects, before any board write.

  Named issue numbers are read one by one and keep the caller's order. A list
  selection walks open issues in GitHub's default order (newest first),
  from `start_page` (the top of the list when omitted), passes over pull
  requests and issues already linked to a live card, and stops at the limit,
  a short page, or the page bound. `next_page` is where that walk stopped, or
  nil when the list is exhausted. Closed, missing, moved and pull-request
  issues are skipped with a reason; any other GitHub failure fails the whole
  import, so nothing is half-imported.
  """
  alias Agentboard.Intake.{Github, Payload}

  # Ten issues per page. A page over the shared 1 MiB cap is re-read in
  # smaller chunks of that same page. A list selection reads at most this
  # many pages before it reports `bounded` and the next page.
  @max_pages 20

  # `linked.(numbers)` maps issue numbers to the live card already linking
  # each one.
  def select(%{"repository" => repository, "selection" => %{"issues" => numbers}}, linked) do
    on_board = linked.(numbers)

    numbers
    |> Enum.reduce_while({:ok, [], []}, fn number, {:ok, picked, skipped} ->
      case Github.issue(repository, number) do
        {:ok, issue} ->
          case classify(repository, number, issue, on_board) do
            {:import, candidate} -> {:cont, {:ok, [candidate | picked], skipped}}
            {:skip, entry} -> {:cont, {:ok, picked, [entry | skipped]}}
          end

        failure ->
          {:halt, failure}
      end
    end)
    |> case do
      {:ok, picked, skipped} ->
        {:ok,
         %{
           picked: Enum.reverse(picked),
           skipped: Enum.reverse(skipped),
           bounded: false,
           next_page: nil
         }}

      failure ->
        unavailable(failure)
    end
  end

  def select(
        %{"repository" => repository, "selection" => %{"start_page" => start} = selection},
        linked
      )
      when is_integer(start) and start >= 1,
      do: walk(repository, selection, linked, start, [])

  defp walk(_repository, %{"start_page" => start}, _linked, page, picked)
       when is_integer(start) and page >= start + @max_pages,
       do: done(picked, true, page)

  defp walk(repository, %{"labels" => labels, "limit" => limit} = selection, linked, page, picked) do
    case Github.open_issues(repository, labels, page) do
      {:ok, issues, last?} ->
        on_board = linked.(for %{"number" => n} <- issues, is_integer(n), do: n)

        {picked, remaining?} =
          Enum.reduce_while(issues, {picked, false}, fn issue, {acc, _} ->
            if length(acc) >= limit do
              {:halt, {acc, true}}
            else
              # Pagination can shift while it is read; an issue is taken once.
              acc =
                with number when is_integer(number) <- issue["number"],
                     false <- Enum.any?(acc, &(&1["issue_number"] == number)),
                     {:import, candidate} <- classify(repository, number, issue, on_board) do
                  [candidate | acc]
                else
                  _ -> acc
                end

              {:cont, {acc, false}}
            end
          end)

        cond do
          length(picked) >= limit ->
            done(picked, false, if(remaining?, do: page, else: next_page(page, last?)))

          last? ->
            done(picked, false, nil)

          true ->
            walk(repository, selection, linked, page + 1, picked)
        end

      failure ->
        unavailable(failure)
    end
  end

  defp done(picked, bounded, next_page),
    do:
      {:ok, %{picked: Enum.reverse(picked), skipped: [], bounded: bounded, next_page: next_page}}

  defp next_page(_page, true), do: nil
  defp next_page(page, false), do: page + 1

  defp classify(_repository, number, :not_found, _on_board), do: skip(number, "not_found")
  defp classify(_repository, number, :moved, _on_board), do: skip(number, "moved")

  defp classify(repository, number, issue, on_board) do
    cond do
      Map.has_key?(issue, "pull_request") ->
        skip(number, "pull_request")

      issue["state"] != "open" ->
        skip(number, "closed")

      # A transferred issue answers under another repository's URL.
      not is_binary(issue["html_url"]) or
          String.downcase(issue["html_url"]) != canonical_url(repository, number) ->
        skip(number, "moved")

      Map.has_key?(on_board, number) ->
        {:skip,
         %{"issue_number" => number, "reason" => "already_linked", "task_id" => on_board[number]}}

      true ->
        {:import,
         %{
           "issue_number" => number,
           "issue_url" => issue["html_url"],
           "title" => Payload.issue_title(issue["title"], number),
           "description" => Payload.issue_description(issue["html_url"], issue["body"]),
           "labels" => Payload.issue_labels(issue["labels"])
         }}
    end
  end

  defp skip(number, reason), do: {:skip, %{"issue_number" => number, "reason" => reason}}

  # The lowercased form existing card links are matched on.
  def canonical_url(repository, number), do: "https://github.com/#{repository}/issues/#{number}"

  defp unavailable({:retry, "github_unconfigured", _}),
    do: {:error, "github_unconfigured", "The intake GitHub credential is not configured"}

  defp unavailable({_, reason, _}), do: github_error(reason)
  defp unavailable({_, reason}), do: github_error(reason)

  defp github_error(reason),
    do:
      {:error, "github_unavailable", "GitHub could not be read for import; nothing was created",
       %{"reason" => reason}}
end
