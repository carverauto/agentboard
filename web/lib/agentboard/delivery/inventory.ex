defmodule Agentboard.Delivery.Inventory do
  @moduledoc "Task-row then canonical-PR locking; no actor-wide lock, process mailbox or provider I/O."
  alias Agentboard.Board.Operations
  alias Agentboard.Board.Resources.{Task, TaskEvent}
  alias Agentboard.Delivery.{PullRequest, TaskLink}
  alias Agentboard.Repo
  require Ash.Query

  @pr ~r/\Ahttps:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/pull\/([1-9][0-9]*)\z/

  def canonical(url) when is_binary(url) and byte_size(url) <= 2048 do
    case Regex.run(@pr, url) do
      [_, owner, repo, number] ->
        owner = String.downcase(owner)
        repo = String.downcase(repo)
        url = "https://github.com/#{owner}/#{repo}/pull/#{number}"
        id = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
        {:ok, %{id: id, owner: owner, repo: repo, number: number, url: url}}

      _ ->
        {:error, :invalid_pr}
    end
  end

  def canonical(_), do: {:error, :invalid_pr}

  # Caller holds the task row (or just created it) inside Board's transaction.
  # Metadata edits without an explicit PR do not manufacture a submission.
  def record(task, event_id, stamp) do
    event = submission_event(task)
    attribution = if event && event.id == event_id, do: "submission", else: attribution(event)
    persist(task, event, stamp, attribution)
  end

  def discover(after_id, limit)
      when (is_nil(after_id) or is_binary(after_id)) and is_integer(limit) and limit in 1..100 do
    query = Task |> Ash.Query.filter(not is_nil(pr_url)) |> Ash.Query.sort(id: :asc)
    query = if after_id, do: Ash.Query.filter(query, id > ^after_id), else: query

    with {:ok, candidates} <- query |> Ash.Query.limit(limit + 1) |> Ash.read(),
         {:ok, counts} <- discover_page(Enum.take(candidates, limit)) do
      {:ok,
       Map.put(
         counts,
         :next_cursor,
         if(length(candidates) > limit, do: Enum.at(candidates, limit - 1).id)
       )}
    else
      _ -> {:error, "unavailable", "PR discovery is unavailable"}
    end
  end

  def discover(_, _),
    do: {:error, "invalid_input", "Discovery needs a task cursor and a limit from 1 to 100"}

  defp discover_page(tasks) do
    Enum.reduce_while(tasks, {:ok, %{scanned: 0, linked: 0, skipped: 0}}, fn task,
                                                                             {:ok, counts} ->
      case Operations.transaction(fn ->
             Operations.lock_task(task.id)
             current = Ash.get!(Task, task.id)
             discover_task(current)
           end) do
        {:ok, disposition} ->
          counts = Map.update!(counts, :scanned, &(&1 + 1)) |> Map.update!(disposition, &(&1 + 1))
          {:cont, {:ok, counts}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp discover_task(task) do
    case canonical(task.pr_url) do
      {:ok, _} ->
        # Only the event that introduced this canonical URL is evidence of submission;
        # later claim/handoff/status events carry mutable ownership snapshots.
        event = submission_event(task)
        persist(task, event, Operations.now(), attribution(event))

      _ ->
        :skipped
    end
  end

  defp submission_event(task) do
    TaskEvent
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.Query.filter(
      fragment(
        "lower(?->'after'->>'pr_url') = lower(?) AND (lower(?->'before'->>'pr_url') IS DISTINCT FROM lower(?->'after'->>'pr_url'))",
        data,
        ^task.pr_url,
        data,
        data
      )
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  defp attribution(nil), do: "unknown"
  defp attribution(_event), do: "timeline"

  defp persist(task, event, stamp, attribution) do
    actor =
      if event,
        do: %{"agent" => event.actor_id, "model" => event.model, "harness" => event.harness},
        else: nil

    {:ok, attrs} = canonical(task.pr_url)
    <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "agentboard-pr:" <> attrs.id)
    Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])

    provenance =
      actor || %{"agent" => "delivery-discovery", "model" => "system", "harness" => "ash"}

    if is_nil(Ash.get!(PullRequest, attrs.id, not_found_error?: false)) do
      Operations.create(PullRequest, :record, Map.put(attrs, :created_at, stamp), provenance)
    end

    existing =
      TaskLink
      |> Ash.Query.filter(task_id == ^task.id and pull_request_id == ^attrs.id)
      |> Ash.read_one!()

    if existing do
      :skipped
    else
      Operations.create(
        TaskLink,
        :record,
        %{
          task_id: task.id,
          pull_request_id: attrs.id,
          submitted_by_id: actor && actor["agent"],
          model: actor && actor["model"],
          harness: actor && actor["harness"],
          source_event_id: event && event.id,
          attribution: attribution,
          linked_at: event && event.created_at,
          recorded_at: stamp
        },
        provenance
      )

      :linked
    end
  end
end
