defmodule Agentboard.Delivery.WorkflowMonitor do
  @moduledoc "Fenced run observations, immutable-submitter routing and same-workflow recovery, through audited Ash actions."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.SeatScope
  alias Agentboard.Board.Resources.Agent

  alias Agentboard.Delivery.{
    WorkflowRun,
    WorkflowHealth,
    WorkflowGithub,
    WorkflowWorker,
    TaskLink,
    RepositoryMetadata
  }

  require Ash.Query
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}
  @failures ~w(failure timed_out startup_failure)

  def queue(repository, run_id) do
    if Agentboard.Delivery.Scheduling.enabled?() do
      Ops.transaction(fn ->
        stamp = Ops.now()

        row =
          Ops.create(
            WorkflowRun,
            :queue,
            %{
              id: repository <> "/" <> run_id,
              repository: repository,
              run_id: run_id,
              requested_at: stamp,
              next_poll_at: stamp
            },
            @actor
          )

        enqueue(row.id)
        %{id: row.id, queued: true}
      end)
    else
      {:error, "disabled", "PR observation is disabled"}
    end
  end

  def tick do
    if Agentboard.Delivery.Scheduling.enabled?() do
      Ops.transaction(fn ->
        stamp = Ops.now()

        rows =
          WorkflowRun
          |> Ash.Query.filter(
            next_poll_at <= ^stamp and
              (is_nil(processed_at) or requested_at > processed_at) and
              (is_nil(lease_expires_at) or lease_expires_at <= ^stamp)
          )
          |> Ash.Query.sort(next_poll_at: :asc, id: :asc)
          |> Ash.Query.limit(100)
          |> Ash.read!()

        Enum.each(rows, &enqueue(&1.id))
        %{scheduled: length(rows)}
      end)
    else
      snooze()
    end
  end

  def check(id) do
    if Agentboard.Delivery.Scheduling.enabled?() do
      case reserve(id) do
        {:ok, nil} -> {:ok, %{skipped: true}}
        {:ok, reserved} -> collect(reserved)
        {:error, _, message} -> {:error, message}
      end
    else
      snooze()
    end
  end

  defp enqueue(id), do: %{"id" => id} |> WorkflowWorker.new() |> Oban.insert!()
  defp snooze, do: {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}

  defp locked(resource, id),
    do: resource |> Ash.Query.filter(id == ^id) |> Ash.Query.lock(:for_update) |> Ash.read_one!()

  defp reserve(id) do
    Ops.transaction(fn ->
      row = locked(WorkflowRun, id)
      stamp = Ops.now()

      if row && DateTime.compare(row.next_poll_at, stamp) != :gt &&
           (is_nil(row.processed_at) ||
              DateTime.compare(row.requested_at, row.processed_at) == :gt) &&
           (is_nil(row.lease_expires_at) || DateTime.compare(row.lease_expires_at, stamp) != :gt) do
        row =
          Ops.update(
            row,
            :reserve,
            %{generation: row.generation + 1, lease_expires_at: DateTime.add(stamp, 180)},
            @actor
          )

        # Shared repository metadata needs its own clock: per-run generations
        # cannot order two collectors for different runs in the same repository.
        {row, reserve_metadata(row)}
      end
    end)
  end

  defp reserve_metadata(row) do
    # Legacy workflow intake permits mixed case and a wider repository syntax.
    # Canonicalize this optional metadata identity without changing that intake or
    # preventing valid retained workflow observations for unsupported identities.
    if repository = SeatScope.canonical_repo(row.repository) do
      Ops.create(RepositoryMetadata, :enroll, %{id: repository}, @actor)
      metadata = locked(RepositoryMetadata, repository)

      Ops.update(
        metadata,
        :reserve,
        %{generation: metadata.generation + 1, last_error: "collection_pending"},
        @actor
      ).generation
    end
  end

  defp collect({reserved, metadata_generation}) do
    case WorkflowGithub.collect(reserved) do
      {:ok, result} ->
        commit(reserved, metadata_generation, result)

      {:error, reason, seconds} ->
        Ops.transaction(fn ->
          row = locked(WorkflowRun, reserved.id)

          if row.generation == reserved.generation do
            Ops.update(
              row,
              :observe,
              %{
                last_error: reason,
                lease_expires_at: nil,
                next_poll_at: DateTime.add(Ops.now(), min(max(seconds, 60), 604_800))
              },
              @actor
            )

            if metadata_generation do
              metadata = locked(RepositoryMetadata, SeatScope.canonical_repo(reserved.repository))

              if metadata.generation == metadata_generation,
                do: Ops.update(metadata, :defer, %{last_error: reason}, @actor)
            end
          end

          %{deferred: reason}
        end)
    end
  end

  defp commit(reserved, metadata_generation, %{ignored: true} = result) do
    Ops.transaction(fn ->
      row = locked(WorkflowRun, reserved.id)

      if current?(row, reserved) do
        Ops.update(
          row,
          :observe,
          %{
            processed_at: reserved.requested_at,
            lease_expires_at: nil,
            last_error: "not_default_branch",
            observed_at: Ops.now()
          },
          @actor
        )

        commit_metadata(reserved, metadata_generation, result)
      end

      %{ignored: true}
    end)
  end

  defp commit(reserved, metadata_generation, result) do
    key =
      :crypto.hash(
        :sha256,
        reserved.repository <> "/" <> result.branch <> "/" <> result.workflow_id
      )
      |> Base.encode16(case: :lower)

    # Materialize the serialization row before locking it, even on first delivery.
    with {:ok, _} <-
           Ops.transaction(fn -> Ops.create(WorkflowHealth, :enroll, %{id: key}, @actor) end) do
      Ops.transaction(fn ->
        health = locked(WorkflowHealth, key)
        row = locked(WorkflowRun, reserved.id)

        if current?(row, reserved) do
          outcome = record_result(row, reserved, result, health)
          # Acquire the shared metadata lock only after recovery has locked all
          # older run rows. Reservation holds its own run before metadata; taking
          # metadata earlier here would invert that order during resolve_older.
          commit_metadata(reserved, metadata_generation, result)
          outcome
        else
          %{superseded: true}
        end
      end)
    end
  end

  defp commit_metadata(_, nil, _), do: :ok

  defp commit_metadata(reserved, generation, result) do
    metadata = locked(RepositoryMetadata, SeatScope.canonical_repo(reserved.repository))
    source = result.repository_metadata

    if metadata.generation == generation and source.repository == metadata.id and
         Agentboard.Delivery.Scheduling.enabled?() and
         DateTime.compare(reserved.lease_expires_at, Ops.now()) == :gt and
         RepositoryMetadata.valid_ref?(source.default_ref) do
      Ops.update(
        metadata,
        :observe,
        %{
          default_ref: source.default_ref,
          observed_at: Ops.now(),
          source_generation: generation,
          source_run_id: reserved.id,
          source_run_generation: reserved.generation,
          last_error: nil
        },
        @actor
      )
    end
  end

  defp record_result(row, reserved, result, health) do
    health = green(health, reserved.run_id, result)

    recovered? =
      {health.green_number, health.green_attempt} >= {result.run_number, result.run_attempt}

    stamp = Ops.now()
    failed? = result.conclusion in @failures
    {responsible, tasks} = if failed?, do: attribution(result.pr_id), else: {nil, []}

    attrs =
      Map.take(result, [
        :workflow_id,
        :workflow_name,
        :branch,
        :head_sha,
        :run_number,
        :run_attempt,
        :conclusion,
        :source_url,
        :jobs
      ])

    row =
      Ops.update(
        row,
        :observe,
        Map.merge(attrs, %{
          responsible_id: responsible,
          source_tasks: tasks,
          failed_at: if(failed?, do: row.failed_at || stamp, else: row.failed_at),
          resolved_at: if(recovered?, do: row.resolved_at || stamp),
          resolution_run_id: if(recovered?, do: health.green_run_id),
          processed_at: reserved.requested_at,
          observed_at: stamp,
          lease_expires_at: nil,
          last_error: nil,
          next_poll_at: stamp
        }),
        @actor
      )

    if result.conclusion == "success", do: resolve_older(row, health, stamp)
    if failed? && !recovered?, do: notify(row)
    %{observed: result.conclusion, resolved: recovered?}
  end

  defp current?(row, reserved) do
    Agentboard.Delivery.Scheduling.enabled?() && row.generation == reserved.generation &&
      !is_nil(row.lease_expires_at) && DateTime.compare(row.lease_expires_at, Ops.now()) == :gt
  end

  defp green(health, run_id, %{conclusion: "success"} = result) do
    if {result.run_number, result.run_attempt} > {health.green_number, health.green_attempt},
      do:
        Ops.update(
          health,
          :green,
          %{
            green_number: result.run_number,
            green_attempt: result.run_attempt,
            green_run_id: run_id
          },
          @actor
        ),
      else: health
  end

  defp green(health, _, _), do: health

  defp resolve_older(row, health, stamp) do
    WorkflowRun
    |> Ash.Query.filter(
      repository == ^row.repository and workflow_id == ^row.workflow_id and
        branch == ^row.branch and not is_nil(failed_at) and is_nil(resolved_at) and
        (run_number < ^health.green_number or
           (run_number == ^health.green_number and run_attempt <= ^health.green_attempt))
    )
    |> Ash.Query.lock(:for_update)
    |> Ash.read!()
    |> Enum.each(
      &Ops.update(
        &1,
        :resolve,
        %{resolved_at: stamp, resolution_run_id: health.green_run_id},
        @actor
      )
    )
  end

  defp attribution(nil), do: {coordinator(), []}

  defp attribution(pr_id) do
    links =
      TaskLink
      |> Ash.Query.filter(pull_request_id == ^pr_id)
      |> Ash.Query.limit(101)
      |> Ash.read!()

    owners = links |> Enum.map(& &1.submitted_by_id) |> Enum.uniq()

    owner =
      case owners do
        [id] when is_binary(id) -> if Ash.get!(Agent, id, not_found_error?: false), do: id
        _ -> nil
      end

    if length(links) <= 100 && owner,
      do: {owner, links |> Enum.map(& &1.task_id) |> Enum.uniq()},
      else: {coordinator(), []}
  end

  defp coordinator do
    id = Application.get_env(:agentboard, :coordinator_id)
    if is_binary(id) && Ash.get!(Agent, id, not_found_error?: false), do: id
  end

  defp notify(row) do
    # Observation retains the obligation with cooperation off. Notification is
    # separately gated and never claims a task, alters a lease, or wakes a pane.
    if Application.get_env(:agentboard, :cooperation_enabled, false) &&
         is_nil(row.message_id) && row.responsible_id do
      jobs =
        Enum.map_join(row.jobs, "; ", fn job ->
          job["name"] <> " / " <> Enum.join(job["steps"], ", ") <> " " <> job["url"]
        end)

      message =
        Ops.send_message(
          @actor,
          %{
            "to" => row.responsible_id,
            "body" =>
              "Default-branch CI failure: #{row.repository}@#{row.branch} #{row.head_sha}; " <>
                "#{row.workflow_name}, run #{row.run_id}, attempt #{row.run_attempt}. " <>
                "Sources: #{Enum.join(row.source_tasks, ", ")}. #{jobs}. #{row.source_url}. " <>
                "Obligation retained on /prs; later success of the same workflow resolves it."
          },
          Ops.now()
        )

      Ops.update(row, :observe, %{message_id: message.id}, @actor)
    end
  end

  def health do
    WorkflowRun
    |> Ash.Query.filter(not is_nil(failed_at) and is_nil(resolved_at))
    |> Ash.Query.sort(failed_at: :asc, id: :asc)
    |> Ash.Query.limit(51)
    |> Ash.read!()
    |> Enum.map(&Ops.public/1)
  end
end
