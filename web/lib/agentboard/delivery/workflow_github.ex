defmodule Agentboard.Delivery.WorkflowGithub do
  @moduledoc "Bounded read-only canonical Actions collection; webhook bodies are cues, never CI evidence."
  alias Agentboard.Delivery.{GithubHTTP, Inventory}
  @failures ~w(failure timed_out startup_failure)

  def collect(row) do
    root = "/repos/" <> row.repository
    context = %{deadline: System.monotonic_time(:millisecond) + 90_000, requests: 0}
    with {:ok, repository, context} <- request(root, context),
         true <- is_map(repository) and repository["full_name"] == row.repository and text?(repository["default_branch"], 255),
         {:ok, run, context} <- request(root <> "/actions/runs/" <> row.run_id, context),
         {:ok, result} <- normalize(row, repository["default_branch"], run),
         {:ok, result, context} <- details(root, row, result, context),
         {:ok, after_read, context} <- request(root <> "/actions/runs/" <> row.run_id, context),
         true <- is_map(after_read) and Map.take(run, revision_fields()) == Map.take(after_read, revision_fields()),
         {:ok, after_repo, _} <- request(root, context),
         true <- is_map(after_repo) and after_repo["full_name"] == row.repository and
           after_repo["default_branch"] == repository["default_branch"] do
      {:ok, result}
    else
      {:error, _, _} = error -> error
      _ -> {:error, "incomplete", 60}
    end
  end

  defp revision_fields,
    do: ~w(id workflow_id run_number run_attempt head_sha head_branch head_repository status conclusion event)

  defp normalize(row, branch, run) do
    cond do
      !is_map(run) or !positive?(run["id"]) or to_string(run["id"]) != row.run_id ->
        {:error, "incomplete", 60}
      run["head_branch"] != branch or run["event"] in ~w(pull_request pull_request_target) or
          get_in(run, ["head_repository", "full_name"]) != row.repository ->
        {:ok, %{ignored: true}}
      run["status"] != "completed" ->
        {:error, "pending", 60}
      positive?(run["workflow_id"]) and positive?(run["run_number"]) and positive?(run["run_attempt"]) and
          is_binary(run["head_sha"]) and Regex.match?(~r/\A[a-f0-9]{40}\z/, run["head_sha"]) and
          run["conclusion"] in ~w(success failure timed_out startup_failure cancelled skipped neutral action_required stale) ->
        {:ok, %{workflow_id: to_string(run["workflow_id"]), workflow_name: label(run["name"]),
          run_number: run["run_number"], run_attempt: run["run_attempt"], head_sha: run["head_sha"],
          branch: branch, conclusion: run["conclusion"], jobs: [], pr_id: nil,
          source_url: "https://github.com/#{row.repository}/actions/runs/#{row.run_id}"}}
      true -> {:error, "incomplete", 60}
    end
  end

  defp details(_root, _row, %{ignored: true} = result, context), do: {:ok, result, context}
  defp details(root, row, %{conclusion: conclusion} = result, context) when conclusion in @failures do
    path = root <> "/actions/runs/#{row.run_id}/attempts/#{result.run_attempt}/jobs"
    with {:ok, jobs, context} <- pages(path, "jobs", context),
         {:ok, failed} <- jobs(jobs, row.repository, row.run_id),
         {:ok, pulls, context} <- pages(root <> "/commits/#{result.head_sha}/pulls", nil, context),
         {:ok, pr_id} <- attribution(pulls, row.repository, result) do
      {:ok, %{result | jobs: failed, pr_id: pr_id}, context}
    end
  end
  defp details(_, _, result, context), do: {:ok, result, context}

  defp attribution(pulls, repository, result) do
    merged = Enum.filter(pulls, fn p ->
      is_map(p) && is_binary(p["merged_at"]) && p["merge_commit_sha"] == result.head_sha &&
        get_in(p, ["base", "repo", "full_name"]) == repository &&
        get_in(p, ["base", "ref"]) == result.branch && positive?(p["number"])
    end)
    case merged do
      [pull] ->
        {:ok, pr} = Inventory.canonical("https://github.com/#{repository}/pull/#{pull["number"]}")
        {:ok, pr.id}
      _ -> {:ok, nil}
    end
  end

  defp jobs(rows, repository, run_id) do
    if Enum.all?(rows, fn job ->
      is_map(job) && positive?(job["id"]) && positive?(job["run_id"]) && to_string(job["run_id"]) == run_id &&
        is_list(job["steps"]) && length(job["steps"]) <= 1000
    end) do
      failed = rows |> Enum.filter(&(&1["conclusion"] in @failures))
        |> Enum.take(10) |> Enum.map(fn job ->
          %{"name" => label(job["name"]),
            "steps" => job["steps"] |> Enum.filter(&(is_map(&1) && &1["conclusion"] in @failures))
              |> Enum.take(10) |> Enum.map(&label(&1["name"])),
            "url" => "https://github.com/#{repository}/actions/runs/#{run_id}/job/#{job["id"]}"}
        end)
      {:ok, failed}
    else
      {:error, "incomplete", 60}
    end
  end

  defp pages(path, key, context, page \\ 1, accumulated \\ []) do
    with {:ok, data, context} <- request(path <> "?per_page=100&page=#{page}", context),
         rows when is_list(rows) <- if(key, do: data[key], else: data),
         true <- length(rows) <= 100 and Enum.all?(rows, &is_map/1),
         total <- if(key, do: data["total_count"], else: nil),
         true <- is_nil(key) or (is_integer(total) and total >= 0 and total <= 500) do
      combined = accumulated ++ rows
      cond do
        length(combined) > 500 -> {:error, "incomplete", 60}
        key && length(combined) == total -> {:ok, combined, context}
        !key && length(rows) < 100 -> {:ok, combined, context}
        rows == [] or page >= 5 -> {:error, "incomplete", 60}
        true -> pages(path, key, context, page + 1, combined)
      end
    else
      {:error, _, _} = error -> error
      _ -> {:error, "incomplete", 60}
    end
  end

  defp request(path, context) do
    remaining = context.deadline - System.monotonic_time(:millisecond)
    if context.requests < 32 && remaining > 0 do
      case GithubHTTP.get(path, min(remaining, 10_000)) do
        {:ok, data, _} -> {:ok, data, %{context | requests: context.requests + 1}}
        {:error, _, _} = error -> error
      end
    else
      {:error, "incomplete", 60}
    end
  end

  defp positive?(n), do: is_integer(n) and n > 0
  defp text?(s, cap), do: is_binary(s) and byte_size(s) in 1..cap and !String.contains?(s, ["\u0000", "\r", "\n"])
  defp label(s) do
    if text?(s, 160), do: s, else: "Unnamed (label omitted)"
  end
end
