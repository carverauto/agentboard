defmodule Agentboard.Housekeeping do
  @moduledoc "Reversible Done visibility and persisted archive policy, independent of task ownership."
  use Ash.Domain, backwards_compatible_interface?: false, extensions: [AshPaperTrail.Domain]
  alias Agentboard.Repo
  alias Agentboard.Housekeeping.{Archive, Policy}
  require Ash.Query

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(Archive)
    resource(Policy)
    resource(Agentboard.Housekeeping.Event)
  end

  def settings do
    case Ash.get(Policy, "board") do
      {:ok, %Policy{} = policy} -> {:ok, public_record(policy)}
      _ -> {:error, "unavailable", "Archive policy is unavailable"}
    end
  end

  def save(actor, params) when is_map(params) do
    with true <- actor[:role] == :captain,
         true <- Enum.sort(Map.keys(params)) == ~w(enabled interval_hours retention_days revision),
         true <- is_boolean(params["enabled"]),
         true <- params["retention_days"] in 1..3650,
         true <- params["interval_hours"] in [1, 24, 168],
         true <- is_integer(params["revision"]) do
      transaction(fn ->
        lock_policy()
        policy = Ash.get!(Policy, "board")

        if policy.revision != params["revision"],
          do: conflict("Settings changed; reload before saving")

        now = db_now()
        next = if params["enabled"], do: DateTime.add(now, params["interval_hours"] * 3600)

        attrs =
          Map.take(params, ~w(enabled retention_days interval_hours))
          |> Map.merge(%{
            "revision" => policy.revision + 1,
            "next_run_at" => next,
            "changed_by" => actor.id
          })

        update(policy, attrs, actor) |> public_record()
      end)
    else
      _ -> {:error, "invalid_input", "Invalid archive policy or captain capability"}
    end
  end

  def change(id, archived?, revision, actor) do
    with true <- Agentboard.Input.slug?(id),
         true <- is_integer(revision) and revision >= 0,
         true <- actor[:role] in [:captain, :system] do
      transaction(fn -> change_locked(id, archived?, revision, actor) |> public_record() end)
    else
      _ -> {:error, "invalid_input", "Task, archive revision and captain capability required"}
    end
  end

  def sweep(%{role: :system} = actor) do
    transaction(fn ->
      lock_policy()
      policy = Ash.get!(Policy, "board")
      now = db_now()

      if not policy.enabled or
           (policy.next_run_at && DateTime.compare(policy.next_run_at, now) == :gt) do
        %{archived: 0, skipped: true}
      else
        cutoff = DateTime.add(now, -policy.retention_days * 86_400)

        %{rows: rows} =
          Ecto.Adapters.SQL.query!(
            Repo,
            """
            SELECT t.id, coalesce(a.revision,0) FROM tasks t LEFT JOIN task_archives a ON a.id=t.id
            WHERE t.status='done' AND a.archived_at IS NULL
            AND greatest(t.updated_at,coalesce(a.restored_at,t.updated_at)) <= $1
            ORDER BY t.updated_at,t.id LIMIT 101
            """,
            [cutoff]
          )

        count =
          rows
          |> Enum.take(100)
          |> Enum.count(fn [id, revision] ->
            # Same task-row lock as manual archive/restore; recheck a concurrently restored card.
            Ecto.Adapters.SQL.query!(Repo, "SELECT id FROM tasks WHERE id=$1 FOR UPDATE", [id])
            existing = Ash.get!(Archive, id, not_found_error?: false)

            if existing &&
                 (existing.archived_at ||
                    (existing.restored_at && DateTime.compare(existing.restored_at, cutoff) == :gt)) do
              false
            else
              change_locked(id, true, (existing && existing.revision) || revision, actor)
              true
            end
          end)

        next =
          DateTime.add(now, if(length(rows) > 100, do: 60, else: policy.interval_hours * 3600))

        update(
          policy,
          %{
            last_run_at: now,
            next_run_at: next,
            last_archived_count: count,
            revision: policy.revision + 1,
            changed_by: actor.id
          },
          actor
        )

        %{archived: count, skipped: false}
      end
    end)
  end

  defp change_locked(id, archived?, revision, actor) do
    case Ecto.Adapters.SQL.query!(Repo, "SELECT status FROM tasks WHERE id=$1 FOR UPDATE", [id]).rows do
      [] -> Repo.rollback({:error, "not_found", "Task not found"})
      [["done"]] -> :ok
      _ -> conflict("Only Done tasks may be archived")
    end

    existing = Ash.get!(Archive, id, not_found_error?: false)
    current = (existing && existing.archived_at != nil) || false

    cond do
      current == archived? ->
        existing || %{id: id, archived_at: nil, restored_at: nil, revision: 0}

      ((existing && existing.revision) || 0) != revision ->
        conflict("Archive state changed; reload before acting")

      true ->
        now = db_now()

        attrs = %{
          archived_at: if(archived?, do: now),
          restored_at: if(archived?, do: existing && existing.restored_at, else: now),
          revision: revision + 1,
          changed_by: actor.id
        }

        if existing do
          update(existing, attrs, actor)
        else
          Archive
          |> Ash.Changeset.for_create(:create, Map.put(attrs, :id, id), opts(actor))
          |> Ash.create!()
        end
    end
  end

  defp update(record, attrs, actor),
    do: record |> Ash.Changeset.for_update(:update, attrs, opts(actor)) |> Ash.update!()

  defp opts(actor), do: [actor: actor, context: %{ash_events_metadata: %{actor: actor.id}}]

  defp lock_policy,
    do:
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT id FROM archive_policy WHERE id='board' FOR UPDATE",
        []
      )

  defp db_now do
    %{rows: [[now]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT clock_timestamp()", [])
    now
  end

  defp conflict(message), do: Repo.rollback({:error, "conflict", message})

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} ->
        Phoenix.PubSub.broadcast(
          Agentboard.PubSub,
          "ab_tasks",
          {:board_changed, "ab_tasks", :housekeeping}
        )

        {:ok, result}

      {:error, error} ->
        error
    end
  end

  defp public_record(%Archive{} = row),
    do: Map.take(Map.from_struct(row), ~w(id archived_at restored_at revision changed_by)a)

  defp public_record(%Policy{} = row),
    do:
      Map.take(
        Map.from_struct(row),
        ~w(id enabled retention_days interval_hours next_run_at last_run_at last_archived_count revision changed_by)a
      )

  defp public_record(row), do: row
end

