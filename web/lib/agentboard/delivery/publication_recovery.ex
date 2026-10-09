defmodule Agentboard.Delivery.PublicationRecovery do
  @moduledoc "Budgeted exact-branch discovery, followed by task/canonical-PR tracking transactions."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Task

  alias Agentboard.Delivery.{
    GithubHTTP,
    Inventory,
    PublicationBinding,
    PublicationRecoveryFinding
  }

  alias Agentboard.Repo
  require Ash.Query
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}
  @sha ~r/\A[0-9a-f]{40,64}\z/

  def enabled?,
    do: Application.get_env(:agentboard, :publication_recovery_enabled, false)

  def run(arguments) do
    if enabled?() and Application.get_env(:agentboard, :pr_discovery_enabled, false) do
      result =
        if arguments[:unlinked_phase] do
          Agentboard.Delivery.UnlinkedPublications.page(
            arguments[:repository_cursor],
            arguments[:repository_page]
          )
        else
          with {:ok, %{next_cursor: next} = page} <- page(arguments[:binding_after_id]) do
            args =
              if next,
                do: %{publication_phase: true, binding_after_id: next},
                else: %{unlinked_phase: true}

            {:ok, Map.put(page, :next_arguments, args)}
          end
        end

      with {:ok, %{next_arguments: next} = page} <- result do
        if next,
          do:
            AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links,
              action_arguments:
                Map.put(next, :unlinked_phase, not Map.get(next, :publication_phase, false))
            )

        {:ok, page}
      end
    else
      {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
    end
  end

  def check_retained_mapping(binding, row) do
    task = Ash.get!(Task, binding.task_id)

    with true <- is_binary(task.pr_url) and task.pr_url != row["html_url"],
         {:ok, pr} <- metadata(binding, row) do
      commit(binding, %{reason: "existing_different_url", candidates: [pr]})
    else
      _ -> {:ok, :registered}
    end
  end

  # One binding per durable job limits each execution to ten list requests and
  # one metadata read. Every request independently spends the shared budget.
  def page(cursor) do
    query = PublicationBinding |> Ash.Query.sort(id: :asc) |> Ash.Query.limit(2)
    query = if cursor, do: Ash.Query.filter(query, id > ^cursor), else: query

    with {:ok, rows} <- Ash.read(query),
         {:ok, result} <- visit(List.first(rows)) do
      {:ok, %{disposition: result, next_cursor: if(length(rows) > 1, do: hd(rows).id)}}
    else
      {:error, _reason, seconds} ->
        {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: seconds)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp visit(nil), do: {:ok, :empty}

  defp visit(binding) do
    # Already linked cards need ordinary observation, not another provider
    # search. Different URLs remain eligible for a retained refusal.
    task = Ash.get!(Task, binding.task_id)

    if task.status in ~w(done cancelled) or retained_link?(task, binding) do
      {:ok, :skipped}
    else
      with {:ok, candidates} <- candidates(binding, 1, []),
           {:ok, observation} <- confirm(binding, candidates) do
        commit(binding, observation)
      end
    end
  end

  defp retained_link?(task, binding) do
    %{rows: [[retained]]} =
      Repo.statement!(
        "SELECT EXISTS(SELECT 1 FROM task_events WHERE task_id=$1 AND kind='publication_recovered' AND data->>'binding_id'=$2 AND data->'after'->>'pr_url'=$3)",
        [task.id, binding.id, task.pr_url]
      )

    retained
  end

  defp candidates(binding, page, found) do
    owner = binding.head_repo |> String.split("/") |> hd()

    query =
      URI.encode_query(%{
        state: "open",
        head: owner <> ":" <> binding.branch,
        per_page: 100,
        page: page
      })

    with {:ok, rows, _headers} <-
           GithubHTTP.get("/repos/" <> binding.repo <> "/pulls?" <> query, 10_000) do
      cond do
        not is_list(rows) or length(rows) > 100 ->
          {:error, "incomplete", 60}

        true ->
          matches =
            Enum.flat_map(rows, fn row ->
              case metadata(binding, row) do
                {:ok, attrs} -> [attrs]
                _ -> []
              end
            end)

          found = Enum.uniq_by(found ++ matches, & &1.url)

          cond do
            length(found) > 1 -> {:ok, %{reason: "multiple_open_prs", candidates: found}}
            length(rows) < 100 -> {:ok, %{reason: nil, candidates: found}}
            page == 10 -> {:ok, %{reason: "incomplete_branch_search", candidates: found}}
            true -> candidates(binding, page + 1, found)
          end
      end
    end
  end

  defp confirm(_binding, %{reason: reason, candidates: rows}) when not is_nil(reason),
    do: {:ok, %{reason: reason, candidates: rows}}

  defp confirm(_binding, %{candidates: []}), do: {:ok, %{reason: nil, candidates: []}}

  defp confirm(binding, %{candidates: [listed]}) do
    with {:ok, row, _headers} <-
           GithubHTTP.get("/repos/" <> binding.repo <> "/pulls/" <> listed.number, 10_000),
         {:ok, current} <- metadata(binding, row),
         true <- current.url == listed.url and current.head_sha == listed.head_sha do
      {:ok, %{reason: nil, candidates: [current]}}
    else
      {:error, reason, seconds} -> {:error, reason, seconds}
      _ -> {:error, "incomplete", 60}
    end
  end

  defp metadata(binding, row) when is_map(row) do
    head = row["head"] || %{}
    base = row["base"] || %{}
    head_repo = get_in(head, ["repo", "full_name"])
    target_repo = get_in(base, ["repo", "full_name"])

    with true <- row["state"] == "open",
         true <- is_binary(head_repo) and String.downcase(head_repo) == binding.head_repo,
         true <- is_binary(target_repo) and String.downcase(target_repo) == binding.repo,
         true <- head["ref"] == binding.branch,
         true <- is_binary(head["sha"]) and Regex.match?(@sha, head["sha"]),
         {:ok, attrs} <- Inventory.canonical(row["html_url"]),
         true <- attrs.owner <> "/" <> attrs.repo == binding.repo,
         true <- is_integer(row["number"]) and Integer.to_string(row["number"]) == attrs.number do
      {:ok, Map.merge(attrs, %{head_sha: head["sha"], branch: head["ref"], head_repo: head_repo})}
    else
      _ -> {:error, :invalid_mapping}
    end
  end

  defp metadata(_, _), do: {:error, :invalid_mapping}

  defp commit(binding, observation) do
    case Ops.transaction(fn ->
           # The immutable binding is attribution metadata, not live publication
           # authority. This path changes only tracking metadata on its card.
           Ops.lock_task(binding.task_id)
           task = Ash.get!(Task, binding.task_id)
           stamp = Ops.now()

           if enabled?() and Application.get_env(:agentboard, :pr_discovery_enabled, false) do
             disposition(task, binding, observation, stamp)
           else
             Ops.reject("disabled", "Publication recovery is disabled")
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, "disabled", _message} -> {:error, "disabled", 60}
      {:error, _code, message} -> {:error, message}
    end
  end

  defp disposition(task, binding, observation, stamp) do
    cond do
      task.status in ~w(done cancelled) ->
        :skipped

      not is_binary(task.repo) or String.downcase(task.repo) != binding.repo ->
        finding(task, binding, "task_repository_changed", observation.candidates, stamp)

      observation.reason ->
        finding(task, binding, observation.reason, observation.candidates, stamp)

      observation.candidates == [] ->
        :absent

      true ->
        link(task, binding, hd(observation.candidates), stamp)
    end
  end

  defp link(task, binding, pr, stamp) do
    Inventory.lock(pr.id)

    %{rows: [cards]} =
      Repo.statement!(
        "SELECT ARRAY(SELECT id FROM tasks WHERE lower(pr_url)=lower($1) AND id<>$2 ORDER BY id)",
        [pr.url, task.id]
      )

    cond do
      cards != [[]] ->
        finding(task, binding, "multiple_cards", [pr], stamp)

      not is_nil(task.pr_url) and task.pr_url != pr.url ->
        finding(task, binding, "existing_different_url", [pr], stamp)

      task.pr_url == pr.url ->
        :skipped

      true ->
        current =
          Ops.update(
            task,
            :link,
            %{pr_url: pr.url, revision: task.revision + 1, updated_at: stamp},
            @actor,
            task.revision
          )

        Ops.project_event(
          task.id,
          @actor,
          "publication_recovered",
          "Recovered exact registered branch; PR author remains unknown",
          task.revision,
          current.revision,
          %{
            "before" => Ops.public(task),
            "after" => Ops.public(current),
            "binding_id" => binding.id,
            "declared_bound_by_id" => binding.bound_by_id,
            "observed_head_sha" => pr.head_sha,
            "pr_author" => "unknown"
          },
          stamp
        )

        Inventory.recovered(current, stamp)

        audit(
          binding,
          %{
            "disposition" => "linked",
            "url" => pr.url,
            "head_sha" => pr.head_sha,
            "declared_bound_by_id" => binding.bound_by_id,
            "pr_author" => "unknown"
          },
          stamp
        )

        :linked
    end
  end

  defp finding(task, binding, reason, candidates, stamp),
    do:
      PublicationRecoveryFinding.retain(
        task,
        %{
          binding_id: binding.id,
          repository: binding.repo,
          branch: binding.branch,
          declared_bound_by_id: binding.bound_by_id
        },
        reason,
        candidates,
        stamp
      )

  defp audit(binding, facts, stamp),
    do: PublicationRecoveryFinding.record(binding.id, facts, stamp)
end
