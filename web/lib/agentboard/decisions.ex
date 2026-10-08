defmodule Agentboard.Decisions do
  @moduledoc "Durable captain gates. Task locks precede request and worker locks; no external effect occurs inside a transaction."
  alias Agentboard.{Input, Repo}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Task
  alias Agentboard.Decisions.{Request, Wake}
  require Ash.Query
  @active ~w(open answered)
  @kinds ~w(ask_user_gate approval merge policy credential scope blocked_decision other)

  def held?(task_id, owner_id) do
    %{rows: [[held]]} = Repo.statement!("SELECT board_decision_hold($1,$2)", [task_id, owner_id])
    held
  end

  def request(actor, data) do
    with {:ok, actor} <- Input.actor(actor), {:ok, data} <- prepare_request(data) do
      Ops.transaction(fn ->
        Ops.identity!(actor)
        request_locked(task!(data["task"]), actor, data)
      end)
    end
  end

  defp request_locked(task, actor, data, promotion \\ %{}) do
    key = if is_nil(data["gate"]), do: question_key(data["question"])

    gate =
      data["gate"] ||
        "question:" <>
          key <>
          if(data["new"],
            do:
              ":retry:" <>
                (:crypto.hash(:sha256, data["request_key"]) |> Base.encode16(case: :lower)),
            else: ""
          )

    prior =
      Request |> Ash.Query.filter(task_id == ^task.id and gate_ref == ^gate) |> Ash.read_one!()

    if prior do
      unless prior.requester_id == task.assignee_id and
               prior.requester_id == Map.get(promotion, :requester_id, actor["agent"]) and
               same_request?(prior, data),
             do: Ops.reject("conflict", "Retained request has different ownership or content")

      envelope(prior)
    else
      requester = Map.get(promotion, :requester_id, actor["agent"])
      owner!(task, %{"agent" => requester})

      if data["new"] do
        latest =
          Request
          |> Ash.Query.filter(task_id == ^task.id and question_key == ^key)
          |> Ash.Query.sort(created_at: :desc, id: :desc)
          |> Ash.Query.limit(1)
          |> Ash.read!()

        unless match?([%{status: status}] when status not in @active, latest),
          do: Ops.reject("conflict", "A new generation requires a retained terminal question")
      end

      stamp = Ops.now()

      attrs = %{
        id: Ash.UUID.generate(),
        task_id: task.id,
        requester_id: requester,
        kind: data["kind"],
        gate_ref: gate,
        question: data["question"],
        findings: data["findings"],
        options: data["options"],
        status: "open",
        question_key: key,
        normalization_version: if(key, do: 1),
        retry_key: data["request_key"],
        expires_in: data["expires_in"],
        expires_at: if(data["expires_in"], do: DateTime.add(stamp, data["expires_in"])),
        bound_pr: if(data["kind"] == "merge", do: task.pr_url),
        created_at: stamp,
        updated_at: stamp
      }

      r = Ops.create(Request, :create, Map.merge(attrs, promotion), actor)

      blocked =
        Ops.update(
          task,
          :update,
          %{status: "blocked", revision: task.revision + 1, updated_at: stamp},
          actor,
          task.revision
        )

      event(blocked, task, r, "decision_requested", actor, stamp, data["question"])
      envelope(r)
    end
  end

  # Identity is owned by the server; clients transmit the original text.
  defp question_key(text) do
    canonical =
      text
      |> String.normalize(:nfc)
      |> String.replace(
        ~r/[\x{0009}-\x{000D}\x{0020}\x{0085}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]+/u,
        " "
      )
      |> String.trim()

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  def promote(actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         true <-
           is_map(data) and
             Enum.all?(
               Map.keys(data),
               &(&1 in ~w(task kind question options source_type source_id revision))
             ),
         true <-
           data["source_type"] in ~w(task_event message) and
             bounded?(data["source_id"], 128) and is_integer(data["revision"]),
         {:ok, request} <- prepare_request(Map.take(data, ~w(task kind question options))) do
      Ops.transaction(fn ->
        Ops.identity!(actor)
        task = task!(data["task"])
        if task.assignee_id != actor["agent"], do: authority!(actor)

        prior =
          Request
          |> Ash.Query.filter(
            task_id == ^task.id and
              source_type == ^data["source_type"] and source_id == ^data["source_id"]
          )
          |> Ash.read_one!()

        if prior do
          unless prior.requester_id == task.assignee_id and
                   prior.kind == request["kind"] and
                   question_key(prior.question) == question_key(request["question"]) and
                   prior.options == request["options"],
                 do: Ops.reject("conflict", "Promotion retry differs from the retained request")

          envelope(prior)
        else
          owner!(task, %{"agent" => task.assignee_id})
          source = Agentboard.Decisions.Waiting.source(task.id)

          unless task.revision == data["revision"] &&
                   not is_nil(source) &&
                   source["source_type"] == data["source_type"] &&
                   source["source_id"] == data["source_id"],
                 do:
                   Ops.reject(
                     "conflict",
                     "Owner source or task revision changed; reload before promotion"
                   )

          promoted =
            case prepare_request(Map.put(request, "findings", source["findings"])) do
              {:ok, validated} -> validated
              {:error, code, message} -> Ops.reject(code, message)
            end

          request_locked(task, actor, promoted, %{
            requester_id: task.assignee_id,
            source_type: source["source_type"],
            source_id: source["source_id"],
            promoted_by: actor["agent"]
          })
        end
      end)
    else
      false -> {:error, "invalid_input", "Promotion requires source identity and task revision"}
      error -> error
    end
  end

  # Invoked by the existing scheduled observation action, independent of polling.
  # Default-off and bounded; normal close retains audit and frozen wake custody.
  def cleanup do
    if Application.get_env(:agentboard, :decision_cleanup_enabled, false) do
      actor = %{"agent" => "decision-maintenance", "model" => "system", "harness" => "ash"}
      Ops.register(actor, %{"name" => "Decision maintenance"})

      %{rows: rows} =
        Repo.statement!(
          """
          SELECT r.id::text,r.task_id FROM decision_requests r JOIN tasks t ON t.id=r.task_id
          WHERE r.status='open' AND r.kind<>'ask_user_gate' AND (
            r.expires_at <= clock_timestamp() OR
            (r.kind='merge' AND r.bound_pr=t.pr_url AND EXISTS (
              SELECT 1 FROM delivery_pull_requests pr JOIN delivery_poll_states p ON p.id=pr.id
              WHERE pr.url=r.bound_pr AND p.lifecycle IN ('merged','closed')
                AND p.observed_at >= r.created_at
                AND p.observed_at > clock_timestamp()-interval '180 seconds'
            )))
          ORDER BY r.created_at,r.id LIMIT 100
          """,
          []
        )

      retired = Enum.count(rows, &retire_candidate(&1, actor))
      {:ok, %{retired: retired}}
    else
      {:ok, %{retired: 0, enabled: false}}
    end
  end

  defp retire_candidate([id, task_id], actor) do
    Ops.transaction(fn ->
      task = task!(task_id)

      Repo.statement!(
        "SELECT id FROM decision_requests WHERE id=$1::text::uuid FOR UPDATE",
        [id]
      )

      r = Ops.fetch!(Request, id, "Decision not found")
      reason = cleanup_reason(r, task, Ops.now())

      if r.status == "open" and reason do
        close(task, r, "superseded", actor, reason, Ops.now())
        true
      else
        false
      end
    end)
    |> case do
      {:ok, true} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp cleanup_reason(r, task, stamp) do
    cond do
      r.kind == "ask_user_gate" ->
        nil

      r.expires_at && DateTime.compare(r.expires_at, stamp) != :gt ->
        "expired: explicit non-gate TTL"

      (r.kind == "merge" and r.bound_pr) && r.bound_pr == task.pr_url ->
        %{rows: rows} =
          Repo.statement!(
            """
            SELECT p.lifecycle FROM delivery_pull_requests pr
            JOIN delivery_poll_states p ON p.id=pr.id
            WHERE pr.url=$1 AND p.lifecycle IN ('merged','closed')
              AND p.observed_at >= $2::timestamptz
              AND p.observed_at > clock_timestamp()-interval '180 seconds'
            """,
            [r.bound_pr, r.created_at]
          )

        case rows do
          [[state]] -> "bound PR terminal: " <> state
          _ -> nil
        end

      true ->
        nil
    end
  end

  def mutate(id, action, actor, data) do
    with {:ok, actor} <- Input.actor(actor), :ok <- uuid(id), :ok <- valid_action(action, data) do
      Ops.transaction(fn ->
        Ops.identity!(actor)
        # Read only the immutable task pointer before acquiring the aggregate lock.
        initial = Ops.fetch!(Request, id, "Decision request not found")
        task = task!(initial.task_id)

        Repo.statement!("SELECT id FROM decision_requests WHERE id=$1::text::uuid FOR UPDATE", [
          id
        ])

        request = Ops.fetch!(Request, id, "Decision request not found")
        stamp = Ops.now()
        disposition(task, request, action, actor, data, stamp)
      end)
    end
  end

  defp disposition(task, r, "recommend", actor, data, stamp) do
    authority!(actor)

    unless r.status == "open",
      do: Ops.reject("conflict", "Only open requests accept recommendations")

    if r.recommendation == data["body"] and r.recommended_by == actor["agent"] do
      envelope(r)
    else
      changed =
        Ops.update(
          r,
          :change,
          %{
            recommendation: data["body"],
            recommended_by: actor["agent"],
            recommended_at: stamp,
            updated_at: stamp
          },
          actor
        )

      event(task, task, changed, "decision_recommended", actor, stamp, data["body"])
      envelope(changed)
    end
  end

  defp disposition(task, r, "answer", actor, data, stamp) do
    authority!(actor)

    if r.requester_id == actor["agent"],
      do: Ops.reject("forbidden", "Requesters cannot answer their own request")

    cond do
      r.status in ~w(answered applied) ->
        unless r.answer == data["answer"] and r.answered_by == actor["agent"],
          do: Ops.reject("conflict", "A different answer is already retained")

        envelope(r)

      r.status != "open" ->
        Ops.reject("conflict", "Only open requests can be answered")

      true ->
        unless task.assignee_id == r.requester_id and
                 task.status in ~w(in_progress blocked review),
               do: Ops.reject("conflict", "Request ownership no longer matches its task")

        message =
          Ops.send_message(
            actor,
            %{
              "to" => r.requester_id,
              "task" => task.id,
              "body" =>
                "Decision " <>
                  r.id <>
                  " answered on behalf of captain. Read agentboard decision show " <>
                  r.id <>
                  " and apply the retained answer before ack.\n\nQuestion (verbatim):\n" <>
                  r.question <> "\n\nAnswer (verbatim):\n" <> data["answer"]
            },
            stamp,
            false
          )

        changed =
          Ops.update(
            r,
            :change,
            %{
              status: "answered",
              answer: data["answer"],
              answered_by: actor["agent"],
              answered_at: stamp,
              on_behalf_of: "captain",
              message_id: message.id,
              updated_at: stamp
            },
            actor
          )

        event_id = event(task, task, changed, "decision_answered", actor, stamp, data["answer"])
        changed = Ops.update(changed, :change, %{event_id: event_id}, actor)
        capture_wake(task, changed, actor, stamp)
        envelope(changed)
    end
  end

  defp disposition(task, r, "ack", actor, _data, stamp) do
    requester!(task, r, actor)

    cond do
      r.status == "applied" ->
        envelope(r)

      r.status != "answered" ->
        Ops.reject("conflict", "Only answered requests can be acknowledged")

      is_nil(task.claim_expires_at) or DateTime.compare(task.claim_expires_at, stamp) != :gt ->
        Ops.reject("conflict", "Renew the held task before acknowledging its answer")

      true ->
        changed =
          Ops.update(
            r,
            :change,
            %{status: "applied", applied_at: stamp, updated_at: stamp},
            actor
          )

        event(task, task, changed, "decision_applied", actor, stamp, nil)
        envelope(changed)
    end
  end

  defp disposition(task, r, "withdraw", actor, data, stamp) do
    requester!(task, r, actor)

    cond do
      r.status == "withdrawn" and r.close_reason == data["reason"] ->
        envelope(r)

      r.status not in @active ->
        Ops.reject("conflict", "Only outstanding requests can be withdrawn")

      true ->
        close(task, r, "withdrawn", actor, data["reason"], stamp)
    end
  end

  # Superseding any request supersedes ALL outstanding requests on that task.
  # It neither transfers ownership nor manufactures a fresh lease.
  defp disposition(task, r, "supersede", actor, data, stamp) do
    authority!(actor)

    outstanding =
      Request
      |> Ash.Query.filter(task_id == ^task.id and status in ^@active)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!()

    if outstanding == [] do
      unless r.status == "superseded" and r.closed_by == actor["agent"] and
               r.close_reason == data["reason"],
             do: Ops.reject("conflict", "No outstanding requests to supersede")

      envelope(r)
    else
      Enum.each(outstanding, &close(task, &1, "superseded", actor, data["reason"], stamp))
      envelope(Ops.fetch!(Request, r.id, "Decision request not found"))
    end
  end

  defp close(task, r, status, actor, reason, stamp) do
    changed =
      Ops.update(
        r,
        :change,
        %{
          status: status,
          closed_by: actor["agent"],
          close_reason: reason,
          closed_at: stamp,
          updated_at: stamp
        },
        actor
      )

    wake = Wake |> Ash.Query.filter(request_id == ^r.id) |> Ash.read_one!()

    if wake && wake.route == "seat_watcher" && wake.status == "pending",
      do:
        Ops.update(
          wake,
          :change,
          %{status: "cancelled", reason: reason, updated_at: stamp},
          actor
        )

    event(task, task, changed, "decision_" <> status, actor, stamp, reason)
    envelope(changed)
  end

  defp capture_wake(task, request, actor, stamp) do
    key = "decision:" <> request.id <> ":answer"
    # Reuse Runtime's worker lock order to freeze readiness and audience.
    Repo.statement!("SELECT id FROM cooperation_subscriptions WHERE id=$1 FOR UPDATE", [
      request.requester_id
    ])

    Repo.statement!("SELECT id FROM cooperation_bindings WHERE id=$1 FOR UPDATE", [
      request.requester_id
    ])

    subscription =
      Ash.get!(Agentboard.Cooperation.Subscription, request.requester_id, not_found_error?: false)

    binding =
      Ash.get!(Agentboard.Cooperation.Binding, request.requester_id, not_found_error?: false)

    worker? = eligible?(subscription, binding, task.repo, stamp)

    event =
      if worker?,
        do:
          Agentboard.Cooperation.Runtime.capture(
            %{
              source_key: key,
              kind: "decision_answered",
              repo: task.repo,
              task_id: task.id,
              summary:
                "Captain answered decision " <>
                  request.id <> ". Read decision show; apply then ack.",
              source_url: "/tasks/" <> task.id,
              priority: task.priority
            },
            recipient: request.requester_id
          )

    Ops.create(
      Wake,
      :create,
      %{
        id: Ash.UUID.generate(),
        request_id: request.id,
        requester_id: request.requester_id,
        task_id: task.id,
        source_key: key,
        route: if(worker?, do: "worker", else: "seat_watcher"),
        worker_event_id: event && event.id,
        worker_id: if(worker?, do: request.requester_id),
        status: "pending",
        answered_at: stamp,
        created_at: stamp,
        updated_at: stamp
      },
      actor
    )
  end

  defp eligible?(nil, _, _, _), do: false
  defp eligible?(_, nil, _, _), do: false

  defp eligible?(s, b, repo, stamp) do
    Agentboard.Cooperation.Runtime.enabled?(s) and not s.paused and repo in s.repos and
      not is_nil(b.session_id) and b.adapter_state == "ready" and b.connector_state == "healthy" and
      not is_nil(b.reported_at) and DateTime.diff(stamp, b.reported_at) <= 90 and
      (get_in(b.capabilities, ["idle_wake", "supported"]) == true or
         get_in(b.capabilities, ["turn_start", "supported"]) == true)
  end

  def wake_mutate(id, action, actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         :ok <- uuid(id),
         true <- action in ~w(reserve accept uncertain),
         true <- is_map(data) and Enum.all?(Map.keys(data), &(&1 in ~w(key reason))),
         true <-
           bounded?(data["key"], 128) and
             (is_nil(data["reason"]) or bounded?(data["reason"], 8192)) do
      Ops.transaction(fn ->
        Agentboard.Availability.lock_admission()
        Ops.identity!(actor)
        authority!(actor)
        initial = Ops.fetch!(Wake, id, "Wake not found")
        task!(initial.task_id)
        Repo.statement!("SELECT id FROM decision_wakes WHERE id=$1::text::uuid FOR UPDATE", [id])
        wake = Ops.fetch!(Wake, id, "Wake not found")

        unless wake.route == "seat_watcher",
          do: Ops.reject("conflict", "Worker wakes use existing runtime receipts")

        stamp = Ops.now()
        key = data["key"]

        case {action, wake.status, wake.reservation_key} do
          {"reserve", "pending", nil} ->
            request = Ops.fetch!(Request, wake.request_id, "Decision request not found")

            unless request.status == "answered",
              do: Ops.reject("conflict", "Only an unapplied answer can resume a seat")

            unless Agentboard.Availability.active?(
                     Agentboard.Availability.admission_agent(wake.requester_id)
                   ),
                   do:
                     Ops.reject("conflict", "Requester availability refuses new wake reservation")

            changed =
              Ops.update(
                wake,
                :change,
                %{
                  status: "reserved",
                  reservation_key: data["key"],
                  reserved_at: stamp,
                  updated_at: stamp
                },
                actor
              )

            %{"wake" => Ops.public(changed), "dispatch_allowed" => true}

          {"reserve", _, existing_key} when existing_key == key ->
            %{"wake" => Ops.public(wake), "dispatch_allowed" => false}

          {"accept", status, existing_key}
          when status in ~w(reserved accepted) and existing_key == key ->
            changed =
              if status == "accepted",
                do: wake,
                else:
                  Ops.update(
                    wake,
                    :change,
                    %{status: "accepted", accepted_at: stamp, updated_at: stamp},
                    actor
                  )

            %{"wake" => Ops.public(changed)}

          {"uncertain", status, existing_key}
          when status in ~w(reserved uncertain) and existing_key == key ->
            changed =
              if status == "uncertain",
                do: wake,
                else:
                  Ops.update(
                    wake,
                    :change,
                    %{
                      status: "uncertain",
                      reason: data["reason"] || "Native submission outcome unknown",
                      updated_at: stamp
                    },
                    actor
                  )

            %{"wake" => Ops.public(changed)}

          _ ->
            Ops.reject("conflict", "Wake disposition or reservation key changed")
        end
      end)
    else
      false -> {:error, "invalid_input", "Valid wake action and bounded reservation key required"}
      error -> error
    end
  end

  def show(id) do
    with :ok <- uuid(id), {:ok, result} <- page(%{"id" => id}) do
      case result["decisions"] do
        [r] -> {:ok, %{"decision" => r}}
        [] -> {:error, "not_found", "Decision request not found"}
      end
    end
  end

  def page(filters), do: read_page("decisions", filters)
  def wakes(filters), do: read_page("wakes", filters)

  defp read_page(kind, filters) do
    with {:ok, limit, stale} <- valid_filters(kind, filters),
         {:ok, cursor} <- decode_cursor(Map.put(filters, "resource", kind)) do
      table = if kind == "decisions", do: "decision_requests", else: "decision_wakes"

      mapping = %{
        "id" => "d.id::text",
        "task" => "d.task_id",
        "owner" => "d.requester_id",
        "status" => "d.status",
        "route" => "d.route",
        "repo" => "t.repo"
      }

      {clauses, args} =
        filters
        |> Map.take(
          if(kind == "decisions",
            do: ~w(id task owner status repo),
            else: ~w(id task owner status route repo)
          )
        )
        |> Enum.sort()
        |> Enum.reduce({[], [stale]}, fn {key, value}, {clauses, args} ->
          {clauses ++ ["#{mapping[key]}=$#{length(args) + 1}"], args ++ [value]}
        end)

      {clauses, args} =
        if cursor do
          {clauses ++
             [
               "(d.created_at,d.id)>($#{length(args) + 1}::text::timestamptz,$#{length(args) + 2}::text::uuid)"
             ], args ++ cursor}
        else
          {clauses, args}
        end

      clauses =
        if filters["waiting"] == "true",
          do: clauses ++ ["d.status IN ('open','answered')"],
          else: clauses

      where = if clauses == [], do: "TRUE", else: Enum.join(clauses, " AND ")

      sql = """
      SELECT to_jsonb(d) || jsonb_build_object(
        'waiting_seconds', greatest(0,floor(extract(epoch FROM clock_timestamp()-d.created_at))),
        'requester_stale', (a.last_heartbeat IS NULL OR a.last_heartbeat <= clock_timestamp()-($1::float8*interval '1 second')),
        'claim_expires_at',t.claim_expires_at,
        'held_by_decision',board_decision_hold(t.id,t.assignee_id))
      FROM #{table} d JOIN tasks t ON t.id=d.task_id JOIN agents a ON a.id=d.requester_id
      WHERE #{where} ORDER BY d.created_at,d.id LIMIT #{limit + 1}
      """

      with {:ok, %{rows: rows}} <- Agentboard.Board.query(sql, args, timeout: 2_000) do
        records = rows |> Enum.map(&hd/1) |> Enum.take(limit)

        next =
          if length(rows) > limit,
            do: encode_cursor(Map.put(filters, "resource", kind), List.last(records)),
            else: nil

        {:ok, %{kind => records, "next_cursor" => next}}
      end
    end
  end

  defp valid_filters(kind, filters) when is_map(filters) do
    allowed =
      if kind == "decisions",
        do: ~w(id task owner status repo waiting limit cursor stale_after),
        else: ~w(id task owner status route repo limit cursor stale_after)

    with true <-
           Enum.all?(filters, fn {k, v} ->
             k in allowed and is_binary(v) and byte_size(v) <= 4096
           end),
         true <-
           is_nil(filters["status"]) or
             filters["status"] in if(kind == "decisions",
               do: ~w(open answered applied withdrawn superseded),
               else: ~w(pending reserved accepted uncertain cancelled)
             ),
         true <- is_nil(filters["route"]) or filters["route"] in ~w(worker seat_watcher),
         true <-
           is_nil(filters["waiting"]) or (kind == "decisions" and filters["waiting"] == "true"),
         true <- is_nil(filters["owner"]) or Input.slug?(filters["owner"]),
         true <- is_nil(filters["task"]) or Input.slug?(filters["task"]),
         {limit, ""} when limit in 1..100 <- Integer.parse(Map.get(filters, "limit", "20")),
         {stale, ""} when stale > 0 and stale <= 31_536_000 <-
           Float.parse(Map.get(filters, "stale_after", "600")) do
      {:ok, limit, stale}
    else
      _ -> {:error, "invalid_input", "Invalid decision list filters"}
    end
  end

  defp valid_filters(_, _), do: {:error, "invalid_input", "Decision filters must be an object"}

  defp decode_cursor(%{"cursor" => encoded} = filters) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"filters" => hash, "at" => at, "id" => id}} <- Jason.decode(json),
         true <- hash == digest(filters),
         {:ok, _, _} <- DateTime.from_iso8601(at),
         {:ok, _} <- Ecto.UUID.cast(id) do
      {:ok, [at, id]}
    else
      _ -> {:error, "invalid_input", "Cursor does not match this query"}
    end
  end

  defp decode_cursor(_), do: {:ok, nil}

  defp encode_cursor(filters, r),
    do:
      Jason.encode!(%{"filters" => digest(filters), "at" => r["created_at"], "id" => r["id"]})
      |> Base.url_encode64(padding: false)

  defp digest(filters),
    do:
      :crypto.hash(
        :sha256,
        Jason.encode!(
          filters
          |> Map.drop(~w(cursor limit))
          |> Enum.sort()
          |> Enum.map(fn {k, v} -> [k, v] end)
        )
      )
      |> Base.encode16(case: :lower)

  defp prepare_request(data) when is_map(data) do
    has_findings = Map.has_key?(data, "findings")

    data =
      data
      |> Map.put_new("kind", "approval")
      |> Map.put_new("findings", "")
      |> Map.put_new("options", [])

    gate = data["gate"]

    if Enum.all?(
         Map.keys(data),
         &(&1 in ~w(task kind gate question findings options new request_key expires_in))
       ) and
         Input.slug?(data["task"]) and data["kind"] in @kinds and
         (is_nil(gate) or bounded?(gate, 512)) and bounded?(data["question"], 8192) and
         is_binary(data["findings"]) and String.valid?(data["findings"]) and
         not String.contains?(data["findings"], <<0>>) and byte_size(data["findings"]) <= 65536 and
         is_list(data["options"]) and length(data["options"]) <= 20 and
         Enum.all?(data["options"], &bounded?(&1, 1024)) and
         (data["kind"] != "ask_user_gate" or (not is_nil(gate) and has_findings)) and
         (is_nil(data["new"]) or is_boolean(data["new"])) and
         (data["new"] != true or (is_nil(gate) and bounded?(data["request_key"], 128))) and
         (is_nil(data["request_key"]) or
            (data["new"] == true and bounded?(data["request_key"], 128))) and
         (is_nil(data["expires_in"]) or
            (data["kind"] != "ask_user_gate" and
               is_integer(data["expires_in"]) and data["expires_in"] in 60..2_592_000)),
       do: {:ok, data},
       else: {:error, "invalid_input", "Invalid or oversized decision request"}
  end

  defp prepare_request(_), do: {:error, "invalid_input", "Decision payload must be an object"}

  defp valid_action(action, data) when is_map(data) do
    valid =
      case action do
        "recommend" ->
          Map.keys(data) == ["body"] and bounded?(data["body"], 8192)

        "answer" ->
          Enum.all?(Map.keys(data), &(&1 in ~w(answer on_behalf_of))) and
            bounded?(data["answer"], 8192) and
            Map.get(data, "on_behalf_of", "captain") == "captain"

        "ack" ->
          map_size(data) == 0

        a when a in ~w(withdraw supersede) ->
          Map.keys(data) == ["reason"] and bounded?(data["reason"], 8192)

        _ ->
          false
      end

    if valid, do: :ok, else: {:error, "invalid_input", "Invalid decision action fields"}
  end

  defp valid_action(_, _), do: {:error, "invalid_input", "Decision payload must be an object"}

  defp bounded?(v, n),
    do:
      is_binary(v) and String.valid?(v) and String.trim(v) != "" and
        not String.contains?(v, <<0>>) and byte_size(v) <= n

  defp uuid(id),
    do:
      if(match?({:ok, _}, Ecto.UUID.cast(id)),
        do: :ok,
        else: {:error, "invalid_input", "Decision/wake ID must be a UUID"}
      )

  defp authority!(actor) do
    coordinator = Application.get_env(:agentboard, :coordinator_id)

    unless actor[:decision_admin] == true and
             (actor["agent"] == "captain" or
                (is_binary(coordinator) and actor["agent"] == coordinator)),
           do:
             Ops.reject(
               "forbidden",
               "Verified captain capability and captain/coordinator attribution required"
             )
  end

  defp owner!(task, actor) do
    stamp = Ops.now()

    unless task.status in ~w(in_progress blocked review) and task.assignee_id == actor["agent"] and
             not is_nil(task.claim_expires_at) and
             (DateTime.compare(task.claim_expires_at, stamp) == :gt or
                held?(task.id, task.assignee_id)),
           do: Ops.reject("conflict", "Decision request requires the live task owner")
  end

  defp requester!(task, r, actor) do
    unless actor["agent"] == r.requester_id and task.assignee_id == r.requester_id,
      do: Ops.reject("forbidden", "Only the current requester can apply or withdraw")
  end

  defp task!(id) do
    Ops.lock_task(id)
    Ops.fetch!(Task, id, "Decision task not found")
  end

  defp same_request?(r, data),
    do:
      r.kind == data["kind"] and
        if(r.question_key,
          do: question_key(r.question) == question_key(data["question"]),
          else: r.question == data["question"]
        ) and r.findings == data["findings"] and
        r.options == Map.get(data, "options", []) and r.expires_in == data["expires_in"]

  defp event(task, prior, r, kind, actor, stamp, body),
    do:
      Ops.project_event(
        task.id,
        actor,
        kind,
        body,
        prior.revision,
        task.revision,
        %{"decision_id" => r.id, "status" => r.status},
        stamp
      )

  defp envelope(r) do
    wake = Wake |> Ash.Query.filter(request_id == ^r.id) |> Ash.read_one!()
    %{"decision" => Ops.public(r), "wake" => wake && Ops.public(wake)}
  end
end
