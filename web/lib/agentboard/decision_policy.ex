defmodule Agentboard.DecisionPolicy do
  @moduledoc "Captain-approved immutable policy versions and atomic, event-created answers."
  alias Agentboard.{Captain, Repo}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Task
  alias Agentboard.Decisions.Request
  alias Agentboard.DecisionPolicy.{Approval, Evaluator, Ledger, Schema, State, Version}
  require Ash.Query

  @captain %{
    "agent" => "captain",
    "model" => "human",
    "harness" => "captain",
    :decision_policy_admin => true
  }
  @system %{
    "agent" => "system-decision-policy",
    "model" => "system",
    "harness" => "ash",
    :decision_policy_internal => true
  }

  def mode,
    do:
      if(Application.get_env(:agentboard, :decision_policy_mode) == "apply",
        do: "apply",
        else: "dry_run"
      )

  def system_actor, do: @system

  def validate(data) do
    with :ok <- fields(data, ~w(policy), ~w(policy)),
         {:ok, document} <- Schema.validate(data["policy"]) do
      {:ok, %{"valid" => true, "sha256" => Schema.digest(document), "policy" => document}}
    end
  end

  def list do
    Ops.transaction(fn ->
      state = state!()

      versions =
        Version
        |> Ash.Query.sort(name: :asc, version: :desc)
        |> Ash.Query.limit(100)
        |> Ash.read!()

      %{
        "versions" => Enum.map(versions, &project(&1, state)),
        "state" => Ops.public(state),
        "mode" => mode()
      }
    end)
  end

  def show(id) do
    with :ok <- uuid(id) do
      Ops.transaction(fn -> policy_envelope(version!(id), state!()) end)
    end
  end

  def draft(capability, data) do
    with :ok <- authority(capability),
         :ok <- fields(data, ~w(policy), ~w(policy)),
         {:ok, doc} <- Schema.validate(data["policy"]),
         true <-
           doc["metadata"]["status"] == "draft" and
             not Map.has_key?(doc["metadata"], "approved_by") and
             not Map.has_key?(doc["metadata"], "approved_at") do
      Ops.transaction(fn ->
        state = lock_state!()
        authority!(capability)
        name = doc["metadata"]["name"]
        version = doc["metadata"]["version"]
        hash = Schema.digest(doc)

        prior =
          Version |> Ash.Query.filter(name == ^name and version == ^version) |> Ash.read_one!()

        row =
          if prior do
            unless prior.sha256 == hash and prior.document == doc,
              do: Ops.reject("conflict", "Policy version already retains different content")

            prior
          else
            %{rows: [[latest]]} =
              Repo.statement!(
                "SELECT coalesce(max(version),0) FROM decision_policy_versions WHERE name=$1",
                [name]
              )

            unless version == latest + 1,
              do: Ops.reject("conflict", "A policy edit must create the next version as a draft")

            Ops.create(
              Version,
              :record,
              %{
                id: Ash.UUID.generate(),
                name: name,
                version: version,
                document: doc,
                sha256: hash,
                created_by: "captain",
                created_at: Ops.now()
              },
              @captain
            )
          end

        authority!(capability)
        policy_envelope(row, state)
      end)
    else
      false -> invalid("Drafts require draft status and no approval attestations")
      error -> error
    end
  end

  def approve(id, capability, data) do
    with :ok <- authority(capability),
         :ok <- uuid(id),
         :ok <- fields(data, ~w(sha256), ~w(sha256)),
         true <- hash?(data["sha256"]) do
      Ops.transaction(fn ->
        state = lock_state!()
        authority!(capability)
        version = version!(id)
        digest!(version, data["sha256"])

        unless approval(version),
          do:
            Ops.create(
              Approval,
              :record,
              %{id: id, sha256: version.sha256, approved_by: "captain", approved_at: Ops.now()},
              @captain
            )

        authority!(capability)
        policy_envelope(version, state)
      end)
    else
      false -> invalid("Exact policy sha256 required")
      error -> error
    end
  end

  def activate(id, capability, data) do
    with :ok <- authority(capability),
         :ok <- uuid(id),
         :ok <- fields(data, ~w(sha256 generation), ~w(sha256 generation)),
         true <- hash?(data["sha256"]) and generation?(data["generation"]) do
      Ops.transaction(fn ->
        state = lock_state!()
        authority!(capability)
        generation!(state, data["generation"])
        version = version!(id)
        digest!(version, data["sha256"])

        unless approval(version),
          do: Ops.reject("conflict", "The exact version requires captain approval")

        updated =
          if state.active_id == id,
            do: state,
            else:
              Ops.update(
                state,
                :replace,
                %{active_id: id, generation: state.generation + 1, updated_at: Ops.now()},
                @captain
              )

        authority!(capability)
        policy_envelope(version, updated)
      end)
    else
      false -> invalid("Policy sha256 and expected nonnegative generation required")
      error -> error
    end
  end

  def deactivate(capability, data) do
    with :ok <- authority(capability),
         :ok <- fields(data, ~w(generation), ~w(generation)),
         true <- generation?(data["generation"]) do
      Ops.transaction(fn ->
        state = lock_state!()
        authority!(capability)
        generation!(state, data["generation"])

        updated =
          if is_nil(state.active_id),
            do: state,
            else:
              Ops.update(
                state,
                :replace,
                %{active_id: nil, generation: state.generation + 1, updated_at: Ops.now()},
                @captain
              )

        authority!(capability)
        %{"state" => Ops.public(updated), "mode" => mode()}
      end)
    else
      false -> invalid("Expected nonnegative generation required")
      error -> error
    end
  end

  # Runs within request_locked AFTER its task revision increment. An insert
  # failure rolls back the request, blocked task, event and job as one unit.
  def enqueue(request, task) do
    state = state!()

    if mode() == "apply" and state.active_id do
      version = version!(state.active_id)

      if server_apply?(version) and approval(version) do
        snapshot = %{
          "decision_id" => request.id,
          "policy_id" => version.id,
          "policy_sha256" => version.sha256,
          "generation" => state.generation,
          "source_version" => source_version(request, task)
        }

        AshOban.schedule(Agentboard.DecisionPolicy.Runner, :apply_created,
          action_arguments: %{snapshot: snapshot}
        )
      end
    end

    :ok
  end

  def apply_job(snapshot) do
    with :ok <-
           fields(
             snapshot,
             ~w(decision_id policy_id policy_sha256 generation source_version),
             ~w(decision_id policy_id policy_sha256 generation source_version)
           ),
         :ok <- uuid(snapshot["decision_id"]),
         :ok <- uuid(snapshot["policy_id"]),
         true <-
           generation?(snapshot["generation"]) and hash?(snapshot["policy_sha256"]) and
             hash?(snapshot["source_version"]) do
      apply_transaction(snapshot, nil)
    else
      false -> invalid("Invalid captured policy job identity")
      error -> error
    end
  end

  def apply(id, capability, data) do
    with :ok <- authority(capability),
         :ok <- uuid(id),
         :ok <-
           fields(
             data,
             ~w(policy_id generation source_version day answer_sha256),
             ~w(policy_id generation source_version day answer_sha256)
           ),
         :ok <- uuid(data["policy_id"]),
         true <-
           generation?(data["generation"]) and hash?(data["source_version"]) and
             hash?(data["answer_sha256"]) and date?(data["day"]) do
      apply_transaction(Map.put(data, "decision_id", id), capability)
    else
      false ->
        invalid("Apply requires the exact source, generation, UTC day and answer hash from plan")

      error ->
        error
    end
  end

  defp apply_transaction(snapshot, capability) do
    Ops.transaction(fn ->
      initial = Ops.fetch!(Request, snapshot["decision_id"], "Decision not found")
      Ops.lock_task(initial.task_id)
      task = Ops.fetch!(Task, initial.task_id, "Task not found")

      Repo.statement!("SELECT id FROM decision_requests WHERE id=$1::text::uuid FOR UPDATE", [
        initial.id
      ])

      request = Ops.fetch!(Request, initial.id, "Decision not found")
      state = lock_state!()
      if capability, do: authority!(capability)
      stamp = Ops.now()
      version = version!(snapshot["policy_id"])

      cond do
        mode() != "apply" or not server_apply?(version) ->
          skipped("disabled")

        state.active_id != version.id or state.generation != snapshot["generation"] ->
          skipped("policy_changed")

        not is_nil(snapshot["policy_sha256"]) and version.sha256 != snapshot["policy_sha256"] ->
          skipped("policy_changed")

        is_nil(approval(version)) or Schema.digest(version.document) != version.sha256 ->
          skipped("unapproved")

        request.status != "open" ->
          skipped("not_open")

        source_version(request, task) != snapshot["source_version"] ->
          skipped("source_changed")

        not current_source?(request, task, stamp) ->
          skipped("source_ineligible")

        true ->
          evaluate_and_apply(request, task, version, state, snapshot, stamp, capability)
      end
    end)
  end

  defp evaluate_and_apply(request, task, version, state, snapshot, stamp, capability) do
    result = evaluate(request, task, version.document, version, state, stamp)

    if not is_nil(capability) and
         (result["day"] != snapshot["day"] or result["answer_sha256"] != snapshot["answer_sha256"]),
       do: Ops.reject("conflict", "Plan answer or UTC day changed; reload before apply")

    prior =
      Ledger
      |> Ash.Query.filter(
        decision_id == ^request.id and policy_id == ^version.id and
          source_version == ^result["source_version"] and generation == ^state.generation and
          day == ^DateTime.to_date(stamp)
      )
      |> Ash.read_one!()

    cond do
      prior ->
        %{"evaluation" => result, "ledger" => Ops.public(prior), "replayed" => true}

      result["outcome"] == "skip" ->
        %{"evaluation" => result, "replayed" => false}

      true ->
        matched = result["outcome"] == "match"
        if capability, do: authority!(capability)
        # These checks are repeated immediately before the only mutation. The
        # state row remains locked through canonical message/event/wake capture.
        unless mode() == "apply" and server_apply?(version),
          do: Ops.reject("conflict", "Policy mode changed")

        if matched,
          do: Agentboard.Decisions.answer_policy_locked(task, request, result["answer"], stamp)

        ledger =
          Ops.create(
            Ledger,
            :record,
            %{
              id: Ash.UUID.generate(),
              decision_id: request.id,
              policy_id: version.id,
              task_id: task.id,
              gate_ref: request.gate_ref,
              policy_version: version.version,
              policy_sha256: version.sha256,
              source_version: result["source_version"],
              generation: state.generation,
              rule_id: result["rule_id"],
              answer: if(matched, do: result["answer"]),
              answer_sha256: if(matched, do: result["answer_sha256"]),
              limit_key: result["limit_key"],
              day: DateTime.to_date(stamp),
              ci_runs: if(matched, do: result["ci_runs"], else: 0),
              result: if(matched, do: "answered", else: "escalated"),
              reason: result["reason"],
              created_at: stamp
            },
            @system
          )

        %{"evaluation" => result, "ledger" => Ops.public(ledger), "replayed" => false}
    end
  end

  def plan(data) do
    with :ok <- fields(data, ~w(policy include_closed limit cursor), []),
         true <- not Map.has_key?(data, "include_closed") or is_boolean(data["include_closed"]),
         {:ok, limit} <- limit(data["limit"]),
         {:ok, doc} <- optional_document(data) do
      Ops.transaction(fn ->
        state = state!()
        {document, version} = plan_policy!(doc, state)
        filters = Map.take(data, ~w(include_closed)) |> Map.put("sha256", Schema.digest(document))
        {after_sql, args} = cursor!(data["cursor"], filters)
        status = if data["include_closed"], do: "TRUE", else: "r.status='open'"

        %{rows: rows} =
          Repo.statement!(
            "SELECT r.id::text FROM decision_requests r WHERE #{status} #{after_sql} ORDER BY r.created_at,r.id LIMIT #{limit + 1}",
            args
          )

        stamp = Ops.now()

        evaluations =
          rows
          |> Enum.take(limit)
          |> Enum.map(fn [id] ->
            request = Ops.fetch!(Request, id, "Decision not found")
            task = Ops.fetch!(Task, request.task_id, "Task not found")
            evaluate(request, task, document, version, state, stamp)
          end)

        next = if length(rows) > limit, do: encode_cursor(filters, List.last(evaluations))

        %{
          "evaluations" => evaluations,
          "next_cursor" => next,
          "mode" => mode(),
          "state" => Ops.public(state)
        }
      end)
    else
      false -> invalid("include_closed must be boolean")
      error -> error
    end
  end

  def explain(id, data) do
    with :ok <- uuid(id),
         :ok <- fields(data, ~w(policy), []),
         {:ok, doc} <- optional_document(data) do
      Ops.transaction(fn ->
        state = state!()
        {document, version} = plan_policy!(doc, state)
        request = Ops.fetch!(Request, id, "Decision not found")
        task = Ops.fetch!(Task, request.task_id, "Task not found")

        %{
          "evaluation" => evaluate(request, task, document, version, state, Ops.now()),
          "state" => Ops.public(state),
          "mode" => mode()
        }
      end)
    end
  end

  def ledger(data) do
    with :ok <- fields(data, ~w(decision_id policy_id limit cursor), []),
         {:ok, limit} <- limit(data["limit"]),
         :ok <- optional_uuid(data["decision_id"]),
         :ok <- optional_uuid(data["policy_id"]) do
      Ops.transaction(fn ->
        filters = Map.take(data, ~w(decision_id policy_id))
        {after_sql, args} = cursor!(data["cursor"], filters)

        {where, args} =
          Enum.reduce(Enum.sort(filters), {"TRUE", args}, fn {key, value}, {where, args} ->
            {where <> " AND r.#{key}=$#{length(args) + 1}::text::uuid", args ++ [value]}
          end)

        %{rows: rows} =
          Repo.statement!(
            "SELECT to_jsonb(r) FROM decision_policy_ledger r WHERE #{where} #{after_sql} ORDER BY r.created_at,r.id LIMIT #{limit + 1}",
            args
          )

        records = rows |> Enum.take(limit) |> Enum.map(&hd/1)

        %{
          "ledger" => records,
          "next_cursor" =>
            if(length(rows) > limit, do: encode_cursor(filters, List.last(records)))
        }
      end)
    end
  end

  # Bounded metadata only for the coordinator protocol. No answers, findings,
  # policy document, authority, handling receipt or source mutation is exposed.
  def attention(request, task) do
    id = request["id"]
    state = state!()
    version = if state.active_id, do: version!(state.active_id)

    base = %{
      "policy_id" => state.active_id,
      "policy_version" => version && version.version,
      "generation" => state.generation,
      "rule_id" => nil,
      "reason" => nil,
      "escalation_delivery" => "unavailable"
    }

    cond do
      is_nil(version) ->
        Map.put(base, "status", "inactive")

      mode() != "apply" or not server_apply?(version) ->
        Map.put(base, "status", "dry_run")

      true ->
        source = snapshot_version(request, task)

        day = DateTime.to_date(Ops.now())

        query =
          Ledger
          |> Ash.Query.filter(
            decision_id == ^id and policy_id == ^version.id and generation == ^state.generation
          )

        query =
          if request["status"] in ["answered", "applied"] and
               request["answered_by"] == @system["agent"],
             do: Ash.Query.filter(query, result == "answered" and answer == ^request["answer"]),
             else: Ash.Query.filter(query, source_version == ^source and day == ^day)

        row =
          query
          |> Ash.Query.sort(created_at: :desc, id: :desc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!()

        if row,
          do:
            Map.merge(base, %{
              "status" => row.result,
              "reason" => row.reason,
              "rule_id" => row.rule_id
            }),
          else: Map.put(base, "status", "not_evaluated")
    end
  end

  defp evaluate(request, task, document, version, state, stamp) do
    key = limit_key(task)
    day = DateTime.to_date(stamp)

    %{rows: [[answers, runs, answered]]} =
      Repo.statement!(
        """
        SELECT (SELECT count(*) FROM decision_policy_ledger WHERE result='answered' AND limit_key=$1 AND day=$2),
               coalesce((SELECT sum(ci_runs) FROM decision_policy_ledger WHERE result='answered' AND decision_id=$3::text::uuid),0),
               EXISTS(SELECT 1 FROM decision_policy_ledger WHERE result='answered' AND decision_id=$3::text::uuid)
        """,
        [key, day, request.id]
      )

    context = %{
      "answered" => answered,
      "answers_used" => answers,
      "ci_runs_used" => runs,
      "limit_key" => key,
      "day" => Date.to_iso8601(day)
    }

    result = Evaluator.evaluate(document, Ops.public(request), context)

    result =
      if request.status == "open" and not current_source?(request, task, stamp),
        do:
          Map.merge(result, %{
            "outcome" => "skip",
            "reason" => "source_ineligible",
            "answer" => nil,
            "ci_runs" => 0
          }),
        else: result

    Map.merge(
      result,
      Map.merge(context, %{
        "decision_id" => request.id,
        "id" => request.id,
        "created_at" => DateTime.to_iso8601(request.created_at),
        "task_id" => task.id,
        "requester_id" => request.requester_id,
        "gate_ref" => request.gate_ref,
        "policy_id" => version && version.id,
        "policy_sha256" => Schema.digest(document),
        "policy_version" => document["metadata"]["version"],
        "generation" => state.generation,
        "source_version" => source_version(request, task),
        "answer_sha256" => if(is_binary(result["answer"]), do: answer_hash(result["answer"])),
        "escalation_delivery" => "unavailable"
      })
    )
  end

  def source_version(request, task), do: snapshot_version(Ops.public(request), Ops.public(task))

  # JSONB and Jason spell equal UTC timestamps differently. Normalize timestamp
  # values to microseconds before hashing so the coordinator can use the exact
  # same SQL snapshot it returns instead of refetching a newer source.
  defp snapshot_version(request, task) do
    request =
      Map.new(request, fn {key, value} ->
        if String.ends_with?(key, "_at") and is_binary(value) do
          case DateTime.from_iso8601(value) do
            {:ok, stamp, _} -> {key, DateTime.to_unix(stamp, :microsecond)}
            _ -> {key, value}
          end
        else
          {key, value}
        end
      end)

    Schema.digest([request, Map.take(task, ~w(id revision assignee_id status pr_url))])
  end

  defp current_source?(r, t, stamp),
    do:
      t.assignee_id == r.requester_id and t.status in ~w(in_progress blocked review) and
        (is_nil(r.expires_at) or DateTime.compare(r.expires_at, stamp) == :gt)

  defp limit_key(%{pr_url: nil, id: id}), do: "task:" <> id

  defp limit_key(task) do
    case Agentboard.Delivery.Inventory.canonical(task.pr_url) do
      {:ok, pr} -> "pr:" <> pr.url
      _ -> Ops.reject("conflict", "Task PR cannot be canonicalized for the policy budget")
    end
  end

  defp plan_policy!(nil, %{active_id: nil}),
    do:
      Ops.reject(
        "not_found",
        "No active policy; supply a policy document for read-only evaluation"
      )

  defp plan_policy!(nil, state) do
    v = version!(state.active_id)
    {v.document, v}
  end

  defp plan_policy!(document, _), do: {document, nil}
  defp optional_document(%{"policy" => document}), do: Schema.validate(document)
  defp optional_document(_), do: {:ok, nil}

  defp project(version, state) do
    approval = approval(version)

    Ops.public(version)
    |> Map.merge(%{
      "status" =>
        cond do
          state.active_id == version.id -> "active"
          approval -> "approved"
          true -> "draft"
        end,
      "approved_by" => approval && approval.approved_by,
      "approved_at" => approval && DateTime.to_iso8601(approval.approved_at)
    })
  end

  defp policy_envelope(version, state),
    do: %{"policy" => project(version, state), "state" => Ops.public(state), "mode" => mode()}

  defp approval(version) do
    case Ash.get!(Approval, version.id, not_found_error?: false) do
      %{sha256: hash} = row when hash == version.sha256 -> row
      _ -> nil
    end
  end

  defp version!(id), do: Ops.fetch!(Version, id, "Policy version not found")
  defp state!, do: Ops.fetch!(State, "board", "Policy schema unavailable")

  defp lock_state! do
    Repo.statement!("SELECT id FROM decision_policy_state WHERE id='board' FOR UPDATE", [])
    state!()
  end

  defp generation!(state, expected),
    do:
      if(state.generation != expected,
        do: Ops.reject("conflict", "Active policy generation changed; reload")
      )

  defp digest!(version, expected),
    do:
      if(version.sha256 != expected or Schema.digest(version.document) != expected,
        do: Ops.reject("conflict", "Policy digest differs from reviewed version")
      )

  defp server_apply?(v), do: get_in(v.document, ["engine", "server_mode"]) == "apply"

  defp authority(capability),
    do:
      if(Captain.authorized?(capability),
        do: :ok,
        else: {:error, "forbidden", "Current verified captain capability required"}
      )

  defp authority!(capability),
    do:
      if(not Captain.authorized?(capability),
        do: Ops.reject("forbidden", "Current verified captain capability required")
      )

  defp answer_hash(answer), do: :crypto.hash(:sha256, answer) |> Base.encode16(case: :lower)

  defp skipped(reason),
    do: %{"evaluation" => %{"outcome" => "skip", "reason" => reason}, "replayed" => false}

  defp uuid(id),
    do:
      if(match?({:ok, _}, Ecto.UUID.cast(id)),
        do: :ok,
        else: invalid("Policy and decision IDs must be UUIDs")
      )

  defp optional_uuid(nil), do: :ok
  defp optional_uuid(id), do: uuid(id)
  defp generation?(v), do: is_integer(v) and v >= 0 and v <= 9_007_199_254_740_991
  defp hash?(v), do: is_binary(v) and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)

  defp date?(v),
    do: is_binary(v) and byte_size(v) == 10 and match?({:ok, _}, Date.from_iso8601(v))

  defp fields(data, allowed, required),
    do:
      if(
        is_map(data) and Enum.all?(Map.keys(data), &(&1 in allowed)) and
          Enum.all?(required, &Map.has_key?(data, &1)),
        do: :ok,
        else: invalid("Invalid policy fields")
      )

  defp invalid(message), do: {:error, "invalid_input", message}
  defp limit(nil), do: {:ok, 20}
  defp limit(n) when is_integer(n) and n in 1..100, do: {:ok, n}

  defp limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {n, ""} -> limit(n)
      _ -> invalid("Limit must be 1–100")
    end
  end

  defp limit(_), do: invalid("Limit must be 1–100")
  defp cursor!(nil, _), do: {"", []}

  defp cursor!(value, filters) do
    with true <- is_binary(value) and byte_size(value) <= 4096,
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, [hash, stamp, id]} <- Jason.decode(decoded),
         true <- hash == Schema.digest(filters),
         :ok <- uuid(id),
         {:ok, _, _} <- DateTime.from_iso8601(stamp) do
      {"AND (r.created_at,r.id)>($1::text::timestamptz,$2::text::uuid)", [stamp, id]}
    else
      _ -> Ops.reject("invalid_input", "Cursor does not match this query")
    end
  end

  defp encode_cursor(filters, record),
    do:
      [Schema.digest(filters), record["created_at"], record["id"]]
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)
end
