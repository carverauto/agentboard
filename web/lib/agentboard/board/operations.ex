defmodule Agentboard.Board.Operations do
  @moduledoc "Transactional Ash writes; SQL handles scoped locks, the clock and the compatible append-only timeline projection."
  alias Agentboard.{Input, Repo}
  alias Agentboard.Board.Resources.{Agent, Task, TaskEvent, Message}
  require Ash.Query
  require Ash.Expr

  def register(actor, data) do
    with {:ok, actor} <- Input.actor(actor), :ok <- Input.registration(data) do
      case transaction(fn ->
             lock_identity(actor["agent"])
             now = now()

             case Ash.get!(Agent, actor["agent"], not_found_error?: false) do
               nil ->
                 attrs =
                   Map.merge(
                     %{"name" => actor["agent"], "capabilities" => [], "metadata" => %{}},
                     data
                   )
                   |> Map.merge(%{
                     "id" => actor["agent"],
                     "model" => actor["model"],
                     "harness" => actor["harness"],
                     "created_at" => now,
                     "updated_at" => now
                   })

                 %{"agent" => public(create(Agent, :register_new, attrs, actor))}

               %Agent{harness: harness} = agent ->
                 if harness != actor["harness"],
                   do: reject("conflict", "That agent ID belongs to another harness")

                 attrs = Map.merge(data, %{"model" => actor["model"], "updated_at" => now})
                 %{"agent" => public(update(agent, :register, attrs, actor))}
             end
           end) do
        {:ok, _} = ok ->
          # Elastic bot provisioning never fails registration: best-effort
          # enqueue after commit; without provisioner/cloak material this
          # is a no-op and the agent stays on the shared bot.
          Agentboard.Mattermost.ElasticBots.ensure(actor["agent"])
          ok

        error ->
          error
      end
    end
  end

  def heartbeat(id, actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         true <- id == actor["agent"] and is_map(data),
         true <- data["status"] in ~w(busy idle),
         true <-
           Enum.all?(data, fn
             {"status", _} -> true
             {"task", v} -> is_nil(v) or Input.slug?(v)
             {"backend", v} -> Input.text?(v)
             _ -> false
           end) do
      transaction(fn ->
        lock_agent(id)
        agent = identity!(actor)

        if data["task"] do
          task = Ash.get!(Task, data["task"], not_found_error?: false)

          unless task && task.assignee_id == id,
            do: reject("conflict", "Current task must exist and belong to this agent")
        end

        stamp = now()

        metadata =
          if Map.has_key?(data, "backend"),
            do: Map.put(agent.metadata, "backend", data["backend"]),
            else: agent.metadata

        attrs = %{
          reported_status: data["status"],
          current_task_id: data["task"],
          last_heartbeat: stamp,
          updated_at: stamp,
          model: actor["model"],
          metadata: metadata
        }

        %{"agent" => public(update(agent, :heartbeat, attrs, actor))}
      end)
    else
      false -> {:error, "invalid_input", "Invalid heartbeat fields or caller"}
      error -> error
    end
  end

  def mutate(id, action, actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         :ok <- Input.task(action, data),
         true <- Input.slug?(id) do
      transaction(fn ->
        Agentboard.Availability.lock_admission()
        identity!(actor)

        if action == "create" do
          stamp = now()

          attrs =
            Map.merge(
              %{"description" => "", "priority" => 3, "labels" => []},
              Map.delete(data, "id")
            )
            |> Map.merge(%{
              "id" => id,
              "status" => "open",
              "revision" => 1,
              "created_at" => stamp,
              "updated_at" => stamp
            })

          task = create(Task, :create, attrs, actor)
          result(task, nil, action, actor, data, stamp)
        else
          lock_task(id)
          task = fetch!(Task, id, "Task not found")
          stamp = now()

          attrs =
            Agentboard.Board.Transition.attributes(task, action, actor["agent"], data, stamp)

          if action in ~w(assign handoff),
            do: fetch!(Agent, data["to"], "Assignment target must be registered", "invalid_input")

          attrs = Map.merge(attrs, Agentboard.Availability.admit(task, action, actor, data))
          changed = update(task, action_name(action), attrs, actor, task.revision)
          result = result(changed, task, action, actor, data, stamp)

          if action == "handoff" do
            message =
              send_message(
                actor,
                %{"to" => data["to"], "task" => id, "body" => data["note"]},
                stamp,
                false
              )

            Map.put(result, "message_id", message.id)
          else
            result
          end
        end
      end)
    else
      false -> {:error, "invalid_input", "Invalid task ID"}
      error -> error
    end
  end

  # Called only by the merge watcher inside its task -> PollState transaction.
  # A dedicated Ash action records the policy; the compatible update event
  # carries merge proof and captures normal notification intents atomically.
  def complete_merged_pr(task, snapshot, url, snapshots, stamp) do
    if Agentboard.Decisions.held?(task.id, task.assignee_id),
      do: reject("conflict", "Outstanding captain decision prevents terminal disposition")

    actor = %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}

    changed =
      update(
        task,
        :complete_merged_pr,
        %{expected_pr_url: task.pr_url, revision: task.revision + 1, updated_at: stamp},
        actor,
        task.revision
      )

    result =
      result(
        changed,
        task,
        "update",
        actor,
        %{
          "status" => "done",
          "note" =>
            "Automatically completed Review: #{url} was observed merged. CI qualification is unchanged.",
          "merge_evidence" => %{
            "policy" => "merged_review_v1",
            "pull_request_id" => snapshot.pull_request_id,
            "url" => url,
            "snapshot_id" => snapshot.id,
            "generation" => snapshot.generation,
            "observed_at" => snapshot.observed_at,
            "head_sha" => snapshot.head_sha,
            "base_sha" => snapshot.base_sha,
            "ci_state" => snapshot.ci_state,
            "submissions" =>
              Enum.map(snapshots, fn proof ->
                %{
                  "pull_request_id" => proof.pull_request_id,
                  "snapshot_id" => proof.id,
                  "generation" => proof.generation,
                  "head_sha" => proof.head_sha,
                  "base_sha" => proof.base_sha,
                  "observed_at" => proof.observed_at,
                  "ci_state" => proof.ci_state
                }
              end)
          }
        },
        stamp
      )

    notify_task_owner(
      changed,
      actor,
      "PR merged: abort native run. Review completed by system: #{url} was observed merged at #{snapshot.observed_at}. CI qualification is unchanged; investigate any outstanding CI repair obligations before taking new work." <>
        seat_return_nudge(task.id),
      stamp
    )

    result
  end

  # Board-side safety net for Treehouse leases nobody returned (#107): when
  # the task records a launch-seat slot (`agentboard-seat ...` update body),
  # the merge-completion message carries the return instruction. Best-effort;
  # any read failure means no nudge, never a failed disposition.
  defp seat_return_nudge(task_id) do
    case Repo.statement(
           "SELECT body FROM task_events WHERE task_id = $1 AND body LIKE 'agentboard-seat %' ORDER BY id DESC LIMIT 1",
           [task_id],
           timeout: 2_000
         ) do
      {:ok, %{rows: [[body]]}} ->
        path = seat_slot_path(body)

        if path do
          quoted = if String.contains?(path, " "), do: "\"#{path}\"", else: path

          " Seat slot #{quoted}: return it with the same-version `treehouse return #{quoted}` before claiming new work; never --force, never rm -rf."
        else
          ""
        end

      _ ->
        ""
    end
  end

  defp seat_slot_path(body) when is_binary(body) do
    rest =
      case String.split(body, "agentboard-seat ", parts: 2) do
        [_, payload] -> String.trim(payload)
        _ -> ""
      end

    if String.starts_with?(rest, "{") do
      case Jason.decode(rest) do
        {:ok, %{"worktree" => path}} when is_binary(path) and path != "" -> path
        _ -> legacy_seat_path(body)
      end
    else
      legacy_seat_path(body)
    end
  end

  defp seat_slot_path(_), do: nil

  defp legacy_seat_path(body) do
    case Regex.run(~r/worktree=(\S+)/, body || "") do
      [_, path] -> path
      _ -> nil
    end
  end

  # Internal system notifications share the same audited message + notice path.
  # Caller must own the task transaction; do not require a registered human sender.
  def notify_task_owner(task, actor, body, stamp) do
    if task.assignee_id,
      do:
        send_message(actor, %{"to" => task.assignee_id, "task" => task.id, "body" => body}, stamp)
  end

  def message(id, actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         true <- is_map(data),
         true <-
           is_integer(id) or
             (is_nil(id) and Input.text?(data["body"]) and
                (Input.slug?(data["to"]) or Input.slug?(data["task"]))),
         true <-
           Enum.all?(data, fn
             {"body", v} -> Input.text?(v)
             {"kind", v} -> v in ~w(note task_order)
             {key, v} when key in ~w(to task) -> Input.slug?(v)
             _ -> false
           end) do
      transaction(fn ->
        identity!(actor)

        message =
          if is_nil(id) do
            send_message(actor, data, now())
          else
            sql!("SELECT id FROM messages WHERE id=$1 FOR UPDATE", [id])
            message = fetch!(Message, id, "Message not found")

            unless message.recipient_id == actor["agent"],
              do: reject("conflict", "Only the addressed recipient may acknowledge a message")

            if message.read_at,
              do: message,
              else:
                update(
                  message,
                  :acknowledge,
                  %{read_at: now(), read_model: actor["model"], read_harness: actor["harness"]},
                  actor
                )
          end

        %{"message" => public(message)}
      end)
    else
      false -> {:error, "invalid_input", "Invalid message fields"}
      error -> error
    end
  end

  def send_message(actor, data, stamp, capture_notice? \\ true) do
    if data["kind"] == "task_order" do
      Agentboard.Availability.lock_admission()

      unless Input.slug?(data["to"]) and
               Agentboard.Availability.active?(
                 Agentboard.Availability.admission_agent(data["to"])
               ),
             do: reject("conflict", "Task-order routing requires an active named recipient")
    end

    if data["to"],
      do: fetch!(Agent, data["to"], "Message recipient must be registered", "invalid_input")

    if data["task"], do: fetch!(Task, data["task"], "Message task must exist", "invalid_input")

    message =
      create(
        Message,
        :create,
        %{
          sender_id: actor["agent"],
          model: actor["model"],
          harness: actor["harness"],
          recipient_id: data["to"],
          task_id: data["task"],
          kind: Map.get(data, "kind", "note"),
          body: data["body"],
          created_at: stamp
        },
        actor
      )

    if capture_notice?, do: Agentboard.Mattermost.MessageNotice.capture(message, actor, stamp)
    message
  end

  defp result(task, prior, action, actor, data, stamp) do
    event_id =
      project_event(
        task.id,
        actor,
        action,
        data["note"],
        prior && prior.revision,
        task.revision,
        Map.merge(
          %{"before" => prior && public(prior), "after" => public(task)},
          Map.take(data, ["merge_evidence"])
        ),
        stamp
      )

    if task.pr_url && Map.has_key?(data, "pr_url") do
      Agentboard.Delivery.Inventory.record(task, event_id, stamp)
    end

    # Outbound chat intent commits with the mutation; a capture failure rolls
    # both back. Disabled bridge captures nothing (old-event cutoff).
    Agentboard.Mattermost.Bridge.capture(task.id, event_id, action, actor, data, stamp)

    Agentboard.Cooperation.Runtime.capture_task(task, event_id, action, actor)
    Agentboard.Delivery.Accountability.progress(task, action, data, actor, stamp)
    %{"task" => public(task), "event_id" => event_id}
  end

  def identity!(actor) do
    case Ash.get!(Agent, actor["agent"], not_found_error?: false) do
      %Agent{harness: harness} = agent ->
        if harness == actor["harness"],
          do: agent,
          else: reject("invalid_context", "Register a matching agent identity first")

      nil ->
        reject("invalid_context", "Register a matching agent identity first")
    end
  end

  # Non-raising form of identity!/1 for API boundaries that map error
  # codes to statuses instead of rescuing.
  def registered_agent(agent_id, harness) when is_binary(agent_id) and agent_id != "" do
    case Ash.get!(Agent, agent_id, not_found_error?: false) do
      %Agent{harness: ^harness} = agent -> {:ok, agent}
      _ -> {:error, "invalid_context", "Register a matching agent identity first"}
    end
  end

  def registered_agent(_, _),
    do: {:error, "invalid_context", "Register a matching agent identity first"}

  def fetch!(resource, id, message, code \\ "not_found") do
    Ash.get!(resource, id, not_found_error?: false) || reject(code, message)
  end

  def create(resource, action, attrs, actor),
    do: resource |> Ash.Changeset.for_create(action, attrs, options(actor)) |> Ash.create!()

  def update(record, action, attrs, actor, revision \\ nil) do
    changeset = Ash.Changeset.for_update(record, action, attrs, options(actor))

    changeset =
      if revision,
        do: Ash.Changeset.filter(changeset, Ash.Expr.expr(revision == ^revision)),
        else: changeset

    Ash.update!(changeset)
  end

  def project_event(id, actor, kind, body, before_revision, revision, data, stamp) do
    %{rows: [[event_id]]} =
      sql!(
        "INSERT INTO task_events(task_id,actor_id,model,harness,kind,body,old_revision,new_revision,data,created_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id",
        [
          id,
          actor["agent"],
          actor["model"],
          actor["harness"],
          kind,
          body,
          before_revision,
          revision,
          data,
          stamp
        ]
      )

    event_id
  end

  defp options(actor) do
    provenance = %{
      agent: actor["agent"],
      model: actor["model"],
      harness: actor["harness"],
      operation_version: 1
    }

    [
      actor: actor,
      context: %{paper_trail_metadata: %{provenance: provenance}, ash_events_metadata: provenance}
    ]
  end

  def public(row) do
    fields = Ash.Resource.Info.attributes(row.__struct__) |> Enum.map(& &1.name)
    row |> Map.take(fields) |> Jason.encode!() |> Jason.decode!()
  end

  def lock_task(id), do: sql!("SELECT id FROM tasks WHERE id=$1 FOR UPDATE", [id])
  defp lock_agent(id), do: sql!("SELECT id FROM agents WHERE id=$1 FOR UPDATE", [id])

  defp lock_identity(id) do
    <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "agentboard-register:" <> id)
    sql!("SELECT pg_advisory_xact_lock($1)", [key])
    lock_agent(id)
  end

  def now do
    %{rows: [[stamp]]} = sql!("SELECT clock_timestamp()", [])
    stamp
  end

  defp sql!(sql, args), do: Repo.statement!(sql, args)

  def reject(code, message),
    do: raise(Agentboard.Board.OperationError, code: code, message: message)

  def transaction(fun) do
    case Ash.transact(
           [
             Agent,
             Agentboard.Auth.Credential,
             Agentboard.Auth.Observation,
             Agentboard.Availability.Policy,
             Agentboard.Decisions.Request,
             Agentboard.Decisions.Wake,
             Agentboard.Recovery.Episode,
             Agentboard.Recovery.Attempt,
             Task,
             Message,
             TaskEvent,
             Agentboard.Board.AuditEvent,
             Agentboard.Delivery.PullRequest,
             Agentboard.Delivery.DuplicateFinding,
             Agentboard.Delivery.TaskLink,
             Agentboard.Delivery.PollState,
             Agentboard.Delivery.CISnapshot,
             Agentboard.Mattermost.Outbox,
             Agentboard.Mattermost.TaskThread,
             Agentboard.Mattermost.ConversationCoverage,
             Agentboard.Cooperation.Subscription,
             Agentboard.Cooperation.Binding,
             Agentboard.Cooperation.Event,
             Agentboard.Cooperation.Delivery,
             Agentboard.Cooperation.Batch,
             Agentboard.Cooperation.Attempt,
             Agentboard.Cooperation.Receipt,
             Agentboard.Delivery.Obligation,
             Agentboard.Delivery.BaseWatch,
             Agentboard.Delivery.WorkflowRun,
             Agentboard.Delivery.WorkflowHealth,
             Agentboard.Delivery.RebaseFollowUp
           ],
           fun,
           timeout: Repo.write_timeout()
         ) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        normalize(error) || {:error, "unavailable", "Board database is unavailable"}
    end
  rescue
    error in Agentboard.Board.OperationError ->
      {:error, error.code, error.message}

    error in [Ash.Error.Invalid, Ash.Error.Unknown, Ash.Error.Forbidden, Postgrex.Error] ->
      normalize(error) || {:error, "unavailable", "Board database is unavailable"}

    DBConnection.ConnectionError ->
      {:error, "unavailable", "Board database is unavailable"}
  end

  defp normalize({:error, code, message}), do: {:error, code, message}
  # Splode formats unrecognized Postgrex exceptions rather than retaining them.
  # Recover only our declared public rejection codes, never database details.
  defp normalize(%Ash.Error.Unknown.UnknownError{error: error}) when is_binary(error) do
    case Regex.run(
           ~r/\A\*\* \(Postgrex.Error\) ERROR P0001 \(raise_exception\) (invalid_input|invalid_context|not_found|conflict)(?:\n|\z)/,
           error
         ) do
      [_, code] -> {:error, code, "Board operation rejected"}
      _ -> nil
    end
  end

  defp normalize(%{errors: errors}),
    do:
      Enum.find_value(errors, &normalize/1) ||
        {:error, "unavailable", "Board database is unavailable"}

  defp normalize(%{error: error}), do: normalize(error)

  defp normalize(%Ash.Error.Changes.InvalidAttribute{private_vars: vars}) do
    if vars[:constraint_type] == :unique,
      do: {:error, "conflict", "That ID already exists"},
      else: {:error, "invalid_input", "Invalid fields or referenced identity"}
  end

  defp normalize(%Postgrex.Error{
         postgres: %{code: :raise_exception, message: code, detail: detail}
       })
       when code in ~w(invalid_input invalid_context not_found conflict),
       do: {:error, code, detail}

  defp normalize(%Postgrex.Error{postgres: %{code: :unique_violation}}),
    do: {:error, "conflict", "That ID already exists"}

  defp normalize(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :check_violation,
              :not_null_violation,
              :foreign_key_violation,
              :invalid_text_representation,
              :numeric_value_out_of_range
            ],
       do: {:error, "invalid_input", "Invalid fields or referenced identity"}

  defp normalize(_), do: nil

  # Fixed names: arbitrary caller strings never become atoms.
  for name <- ~w(assign claim renew reclaim release edit link update handoff)a do
    defp action_name(unquote(Atom.to_string(name))), do: unquote(name)
  end
end
