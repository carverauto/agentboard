defmodule Agentboard.Coordinator do
  @moduledoc "Decision-only attention and immutable handling, without source or dispatch effects."
  alias Agentboard.{Auth, Repo}
  alias Agentboard.Auth.{APIAuthPolicy, Credential}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Agent
  alias Agentboard.Coordinator.{Batch, Contract, Item}
  require Ash.Query

  def tick(principal, query) do
    with :ok <- enforced(principal),
         {:ok, options} <- Contract.query(query, principal.agent_id) do
      Ops.transaction(fn ->
        current!(principal)

        {where, args} =
          case options.cursor do
            nil ->
              {"d.status='open'", [principal.agent_id]}

            [stamp, id] ->
              {"d.status='open' AND (d.created_at,d.id)>($2::text::timestamptz,$3::text::uuid)",
               [principal.agent_id, stamp, id]}
          end

        rows = sources(where, args, options.limit + 1) |> Enum.map(& &1["item"])
        current_configuration!(principal)

        case Contract.page(rows, principal.agent_id, options) do
          {:ok, packet} -> packet
          {:error, code, message} -> Ops.reject(code, message)
        end
      end)
    end
  end

  def show(principal, id) do
    with :ok <- enforced(principal), true <- Contract.uuid?(id) do
      Ops.transaction(fn ->
        current!(principal)
        source = source!(principal.agent_id, id)
        current_configuration!(principal)
        Map.merge(source, %{"protocol_revision" => 1, "coordinator_id" => principal.agent_id})
      end)
    else
      false -> {:error, "invalid_input", "Canonical lowercase decision UUID required"}
      error -> error
    end
  end

  def acknowledge(principal, data) do
    with :ok <- enforced(principal), {:ok, request} <- Contract.ack(data) do
      Ops.transaction(fn ->
        # Immutable retained batches may be read without touching source locks.
        # New writes always acquire canonical task/decision locks before agent
        # custody, matching Decisions' source-first mutation order.
        case prior(principal.agent_id, request.key) do
          nil ->
            create_receipt(principal, request)

          batch ->
            current!(principal)
            retry!(batch, request)
        end
      end)
    end
  end

  def heartbeat(principal, data) do
    with :ok <- enforced(principal), :ok <- Contract.heartbeat(data) do
      Ops.transaction(fn ->
        if data["task"], do: lock_task(data["task"])
        current!(principal)

        case Agentboard.Board.heartbeat(principal.agent_id, actor(principal), data) do
          {:ok, value} -> Map.put(value, "protocol_revision", 1)
          {:error, code, message} -> Ops.reject(code, message)
        end
      end)
    end
  end

  defp create_receipt(principal, request) do
    ids = Enum.map(request.items, & &1["id"])

    %{rows: pointers} =
      Repo.statement!(
        "SELECT id::text,task_id FROM decision_requests WHERE id::text=ANY($1::text[]) ORDER BY id",
        [ids]
      )

    if length(pointers) != length(ids), do: Ops.reject("not_found", "Decision source not found")
    pointers |> Enum.map(&List.last/1) |> Enum.uniq() |> Enum.sort() |> Enum.each(&lock_task/1)

    Enum.each(
      ids,
      &Repo.statement!("SELECT id FROM decision_requests WHERE id=$1::text::uuid FOR UPDATE", [&1])
    )

    current!(principal)
    lock_key(principal.agent_id, request.key)

    case prior(principal.agent_id, request.key) do
      nil ->
        sources =
          Enum.map(request.items, fn item ->
            source = source!(principal.agent_id, item["id"])["item"]

            unless source["version"] == item["version"] and source["status"] == "open" and
                     is_nil(source["reason"]),
                   do:
                     Ops.reject(
                       "conflict",
                       "Decision version, status or current owner changed; reload"
                     )

            {source, item}
          end)

        stamp = Ops.now()
        current_configuration!(principal)

        batch =
          Ops.create(
            Batch,
            :record,
            %{
              id: Ash.UUID.generate(),
              actor_id: principal.agent_id,
              credential_id: principal.credential_id,
              operation: "ack",
              retry_key: request.key,
              request_hash: request.hash,
              model: principal.model,
              harness: principal.harness,
              item_count: length(sources),
              created_at: stamp
            },
            internal_actor(principal)
          )

        Enum.each(sources, fn {source, item} ->
          Ops.create(
            Item,
            :record,
            %{
              id: Ash.UUID.generate(),
              batch_id: batch.id,
              decision_id: source["id"],
              source_version: source["version"],
              task_id: source["task_id"],
              task_revision: source["task_revision"],
              requester_id: source["requester_id"],
              disposition: item["disposition"],
              created_at: stamp
            },
            internal_actor(principal)
          )
        end)

        current_configuration!(principal)
        receipt(batch)

      batch ->
        retry!(batch, request)
    end
  end

  defp retry!(batch, request) do
    unless batch.request_hash == request.hash,
      do: Ops.reject("conflict", "Retry key already has different handling content")

    receipt(batch)
  end

  defp prior(actor, key),
    do:
      Batch
      |> Ash.Query.filter(actor_id == ^actor and operation == "ack" and retry_key == ^key)
      |> Ash.read_one!()

  defp receipt(batch) do
    items =
      Item
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.Query.sort(decision_id: :asc)
      |> Ash.read!()

    %{
      protocol_revision: 1,
      receipt: %{
        id: batch.id,
        actor_id: batch.actor_id,
        model: batch.model,
        harness: batch.harness,
        retry_key: batch.retry_key,
        created_at: DateTime.to_iso8601(batch.created_at),
        items:
          Enum.map(
            items,
            &%{
              id: &1.decision_id,
              version: &1.source_version,
              disposition: &1.disposition,
              task_id: &1.task_id,
              task_revision: &1.task_revision,
              requester_id: &1.requester_id
            }
          )
      }
    }
  end

  defp source!(actor, id) do
    case sources("d.id=$2::text::uuid", [actor, id], 1) do
      [row] -> row
      [] -> Ops.reject("not_found", "Decision source not found")
    end
  end

  # Hash full canonical decision content in PostgreSQL's deterministic jsonb
  # representation, including source fields not copied into the bounded packet.
  # Task revision/owner changes invalidate handling even if the decision is open.
  defp sources(where, args, limit) do
    # jsonb renders timestamptz in the connection's timezone. Pin this transaction
    # before both hashing and serialization so versions/cursors are portable
    # across sessions, database defaults and deployment timezone changes.
    Repo.statement!("SET LOCAL TIME ZONE 'UTC'", [])

    %{rows: rows} =
      Repo.statement!(
        """
        SELECT jsonb_build_object('decision',to_jsonb(d),'item',jsonb_build_object(
          'id',d.id,'version',v.version,'source_kind','decision_request',
          'status',d.status,'kind',d.kind,'created_at',d.created_at,'updated_at',d.updated_at,
          'task_id',t.id,'task_revision',t.revision,'task_owner_id',t.assignee_id,
          'task_status',t.status,'requester_id',d.requester_id,
          'handling',jsonb_build_object('disposition',h.disposition,'receipt_id',h.batch_id,'handled_at',h.created_at),
          'attention',CASE WHEN d.status<>'open' THEN 'resolved'
                           WHEN t.assignee_id IS DISTINCT FROM d.requester_id OR t.status NOT IN ('in_progress','blocked','review') THEN 'blocked'
                           WHEN h.escalated THEN 'captain_pending' ELSE 'needs_handling' END,
          'reason',CASE WHEN t.assignee_id IS DISTINCT FROM d.requester_id THEN 'owner_changed'
                        WHEN t.status NOT IN ('in_progress','blocked','review') THEN 'task_inactive' ELSE NULL END,
          'refs',jsonb_build_object('source','/api/v1/coordinator/decisions/'||d.id::text,'task','/tasks/'||t.id)))
        FROM decision_requests d JOIN tasks t ON t.id=d.task_id
        CROSS JOIN LATERAL (SELECT encode(sha256(convert_to(jsonb_build_array(to_jsonb(d),
          jsonb_build_object('id',t.id,'revision',t.revision,'owner',t.assignee_id,'status',t.status))::text,'UTF8')),'hex') AS version) v
        LEFT JOIN LATERAL (SELECT i.disposition,i.batch_id,i.created_at,
          bool_or(i.disposition='escalated') OVER () AS escalated FROM coordinator_handling_items i
          JOIN coordinator_handling_batches b ON b.id=i.batch_id
          WHERE i.decision_id=d.id AND i.source_version=v.version AND b.actor_id=$1
          ORDER BY i.created_at DESC,i.id DESC LIMIT 1) h ON true
        WHERE #{where} ORDER BY d.created_at,d.id LIMIT #{limit}
        """,
        args
      )

    Enum.map(rows, &hd/1)
  end

  defp current!(principal) do
    current_configuration!(principal)
    Repo.statement!("SELECT id FROM agents WHERE id=$1 FOR UPDATE", [principal.agent_id])

    Repo.statement!(
      "SELECT id FROM agent_api_credentials WHERE id=$1::text::uuid FOR SHARE",
      [principal.credential_id]
    )

    credential =
      Ops.fetch!(Credential, principal.credential_id, "Credential unavailable", "forbidden")

    agent = Ops.fetch!(Agent, principal.agent_id, "Identity unavailable", "forbidden")

    unless credential.scope == "coordinator_runner" and credential.agent_id == principal.agent_id and
             APIAuthPolicy.credential_allowed?(credential, agent, principal.agent_id) and
             agent.model == principal.model and agent.harness == principal.harness,
           do: Ops.reject("forbidden", "Current authenticated coordinator changed")

    current_configuration!(principal)
    :ok
  end

  defp current_configuration!(principal) do
    case enforced(principal) do
      :ok -> :ok
      {:error, code, message} -> Ops.reject(code, message)
    end
  end

  defp enforced(principal) do
    if Auth.mode() == "enforce" and is_map(principal) and
         principal[:scope] == "coordinator_runner" and
         Contract.uuid?(principal[:credential_id]) and
         is_binary(principal[:agent_id]) and
         principal[:agent_id] == Application.get_env(:agentboard, :coordinator_id),
       do: :ok,
       else: {:error, "forbidden", "Enforced authenticated coordinator runner required"}
  end

  defp lock_key(actor, key) do
    <<lock::signed-64, _::binary>> =
      :crypto.hash(:sha256, Jason.encode!(["coordinator", actor, "ack", key]))

    Repo.statement!("SELECT pg_advisory_xact_lock($1)", [lock])
  end

  # A legacy participant heartbeat locks its agent before updating the task FK,
  # whose KEY SHARE lock must remain compatible. NO KEY UPDATE still excludes
  # every canonical source/owner writer's FOR UPDATE without that inversion.
  defp lock_task(id),
    do: Repo.statement!("SELECT id FROM tasks WHERE id=$1 FOR NO KEY UPDATE", [id])

  defp actor(principal),
    do: %{
      "agent" => principal.agent_id,
      "model" => principal.model,
      "harness" => principal.harness
    }

  defp internal_actor(principal), do: Map.put(actor(principal), :coordinator_internal, true)
end
