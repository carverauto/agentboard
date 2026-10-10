defmodule Agentboard.Delivery.UnlinkedPublications do
  @moduledoc "Paginated registered-repository backstop; retain captain attribution gaps without guessing a card."
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

  # Only repositories with registered branches enter this bounded backstop.
  # Pages do not auto-link: exact branch searches above prove uniqueness first.
  # Unbound PRs get a separate attribution card, never a guessed source owner.
  def page(cursor, page) do
    repository =
      if page > 1 do
        %{rows: rows} =
          Repo.statement!(
            "SELECT repo FROM delivery_publication_bindings WHERE repo=$1 LIMIT 1",
            [cursor]
          )

        case rows do
          [[repo]] -> repo
          [] -> nil
        end
      else
        %{rows: rows} =
          Repo.statement!(
            "SELECT DISTINCT repo FROM delivery_publication_bindings WHERE ($1::text IS NULL OR repo>$1) ORDER BY repo LIMIT 1",
            [cursor]
          )

        case rows do
          [[repo]] -> repo
          [] -> nil
        end
      end

    if repository do
      query =
        URI.encode_query(%{
          state: "open",
          per_page: 100,
          page: page,
          sort: "created",
          direction: "asc"
        })

      with {:ok, rows, _headers} <-
             GithubHTTP.get("/repos/" <> repository <> "/pulls?" <> query, 10_000),
           true <- is_list(rows) and length(rows) <= 100,
           {:ok, _} <- unlinked_rows(repository, rows) do
        more? = length(rows) == 100 and page < 10

        if length(rows) == 100 and page == 10 do
          # The cap is a retained operator finding, never a complete-search claim.
          case unlinked_finding(
                 repository,
                 %{
                   id: :crypto.hash(:sha256, repository) |> Base.encode16(case: :lower),
                   url: nil,
                   branch: nil,
                   head_repo: nil
                 },
                 "repository_search_limit"
               ) do
            {:ok, _} -> :ok
            {:error, _code, message} -> Ops.reject("unavailable", message)
          end
        end

        {:ok,
         %{
           scanned: length(rows),
           next_arguments: %{
             repository_cursor: repository,
             repository_page: if(more?, do: page + 1, else: 1)
           }
         }}
      else
        {:error, _reason, seconds} ->
          {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: seconds)}

        false ->
          {:error, "Provider repository page is incomplete"}

        {:error, error} ->
          {:error, error}
      end
    else
      {:ok, %{scanned: 0, next_arguments: nil}}
    end
  end

  defp unlinked_rows(repository, rows) do
    Enum.reduce_while(rows, {:ok, :ok}, fn row, _ ->
      case unlinked_row(repository, row) do
        {:ok, _} ->
          {:cont, {:ok, :ok}}

        {:error, "disabled", _message} ->
          {:halt, {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}}

        {:error, _code, message} ->
          {:halt, {:error, message}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp unlinked_row(repository, row) do
    with {:ok, pr} <- Inventory.canonical(if(is_map(row), do: row["html_url"])),
         true <- pr.owner <> "/" <> pr.repo == repository and row["state"] == "open" do
      head_repo = get_in(row, ["head", "repo", "full_name"])
      branch = get_in(row, ["head", "ref"])

      matches =
        if is_binary(head_repo) and is_binary(branch) do
          normalized = String.downcase(head_repo)

          PublicationBinding
          |> Ash.Query.filter(
            repo == ^repository and head_repo == ^normalized and branch == ^branch
          )
          |> Ash.read!()
        else
          []
        end

      if matches == [] do
        unlinked_finding(
          repository,
          Map.merge(pr, %{branch: branch, head_repo: head_repo}),
          "missing_unique_binding"
        )
      else
        binding = hd(matches)
        task = Ash.get!(Task, binding.task_id)

        if task.status in ~w(done cancelled) and task.pr_url != pr.url do
          unlinked_finding(
            repository,
            Map.merge(pr, %{branch: branch, head_repo: head_repo}),
            "terminal_bound_card"
          )
        else
          Agentboard.Delivery.PublicationRecovery.check_retained_mapping(binding, row)
        end
      end
    else
      _ -> {:ok, :invalid_provider_row}
    end
  end

  defp unlinked_finding(repository, pr, reason) do
    task_id = "unlinked-publication-" <> pr.id

    Ops.transaction(fn ->
      # Serialize creation of a missing captain card before taking task/PR
      # locks. Existing public writers keep their normal task -> PR order.
      <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "unlinked-publication:" <> pr.id)
      Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])
      Ops.lock_task(task_id)
      Inventory.lock(pr.id)
      stamp = Ops.now()

      unless Agentboard.Delivery.PublicationRecovery.enabled?() and
               Application.get_env(:agentboard, :pr_discovery_enabled, false),
             do: Ops.reject("disabled", "Publication recovery is disabled")

      %{rows: [[linked]]} =
        Repo.statement!("SELECT EXISTS(SELECT 1 FROM tasks WHERE lower(pr_url)=lower($1))", [
          pr.url
        ])

      if linked do
        :already_linked
      else
        task =
          Ash.get!(Task, task_id, not_found_error?: false) ||
            Ops.create(
              Task,
              :create,
              %{
                id: task_id,
                title: "Unlinked publication attribution",
                description:
                  "Repository #{repository}; PR #{pr.url || "unknown"}; actual author unknown.",
                repo: repository,
                labels: ["publication-attribution"],
                priority: 0,
                status: "open",
                revision: 1,
                created_at: stamp,
                updated_at: stamp
              },
              @actor
            )

        mapping = %{
          binding_id: nil,
          repository: repository,
          branch: pr.branch,
          declared_bound_by_id: nil
        }

        PublicationRecoveryFinding.retain(
          task,
          mapping,
          reason,
          if(pr.url, do: [pr], else: []),
          stamp
        )
      end
    end)
  end
end
