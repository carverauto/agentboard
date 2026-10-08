defmodule Agentboard.Delivery.Publication do
  @moduledoc "Owner-fenced publication attribution through the Board API; no provider I/O under locks."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Task
  alias Agentboard.Delivery.PublicationBinding
  alias Agentboard.{Input, Repo}
  require Ash.Query
  @repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/

  def bind(actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         :ok <- validate(data) do
      Ops.transaction(fn ->
        Ops.identity!(actor)
        Ops.lock_task(data["task"])
        task = Ops.fetch!(Task, data["task"], "Publication task is missing")
        stamp = Ops.now()
        owner!(task, actor, stamp)
        repo = String.downcase(data["repo"])
        head_repo = String.downcase(data["head_repo"])

        unless is_binary(task.repo) and String.downcase(task.repo) == repo,
          do: Ops.reject("conflict", "Publication repository does not match the owned task")

        # All binding writers take task -> exact branch key. Never acquire a
        # task or a base lock beneath this key; the unique index is a backstop.
        <<key::signed-64, _::binary>> =
          :crypto.hash(:sha256, "publication-binding:" <> head_repo <> ":" <> data["branch"])

        Repo.statement!("SELECT pg_advisory_xact_lock($1)", [key])

        prior =
          PublicationBinding
          |> Ash.Query.filter(head_repo == ^head_repo and branch == ^data["branch"])
          |> Ash.read_one!()

        # The branch-key lock/read can wait beyond the initial claim check.
        # Sample the database clock again at the attribution write boundary.
        stamp = Ops.now()
        owner!(task, actor, stamp)

        binding =
          if prior do
            unless prior.task_id == task.id and prior.repo == repo,
              do:
                Ops.reject(
                  "conflict",
                  "Exact head branch is already bound to another card/repository"
                )

            prior
          else
            Ops.create(
              PublicationBinding,
              :bind,
              %{
                id: Ash.UUID.generate(),
                repo: repo,
                head_repo: head_repo,
                branch: data["branch"],
                task_id: task.id,
                bound_by_id: actor["agent"],
                generation: 1,
                created_at: stamp
              },
              actor
            )
          end

        %{"binding" => Ops.public(binding), "idempotent" => not is_nil(prior)}
      end)
    end
  end

  defp owner!(task, actor, stamp) do
    unless task.status not in ~w(done cancelled) and task.assignee_id == actor["agent"] and
             not is_nil(task.claim_expires_at) and
             DateTime.compare(task.claim_expires_at, stamp) == :gt,
           do: Ops.reject("conflict", "Publication requires this actor's live task claim")

    if Agentboard.Decisions.held?(task.id, task.assignee_id),
      do: Ops.reject("conflict", "Publication cannot bypass an unresolved task decision")
  end

  defp validate(data) when is_map(data) do
    if Map.keys(data) |> Enum.sort() == Enum.sort(~w(task repo head_repo branch)) and
         Input.slug?(data["task"]) and repository?(data["repo"]) and
         repository?(data["head_repo"]) and branch?(data["branch"]),
       do: :ok,
       else:
         {:error, "invalid_input",
          "Binding requires a task, canonical repo/head_repo and exact short branch"}
  end

  defp validate(_), do: {:error, "invalid_input", "Binding payload must be an object"}

  defp repository?(value),
    do: is_binary(value) and byte_size(value) <= 255 and Regex.match?(@repository, value)

  defp branch?(value) when is_binary(value) and byte_size(value) in 1..255 do
    forbidden = ["~", "^", ":", "?", "*", "[", "\\", "..", "@{", "//"]

    value != "@" and not String.starts_with?(value, ["/", "refs/"]) and
      not String.ends_with?(value, ["/", "."]) and
      not Enum.any?(forbidden, &String.contains?(value, &1)) and
      not Enum.any?(String.to_charlist(value), &(&1 <= 32 or &1 == 127)) and
      not Enum.any?(
        String.split(value, "/"),
        &(String.starts_with?(&1, ".") or String.ends_with?(&1, ".lock"))
      )
  end

  defp branch?(_), do: false
end
