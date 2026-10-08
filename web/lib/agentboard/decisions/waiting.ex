defmodule Agentboard.Decisions.Waiting do
  @moduledoc "One SQL snapshot supplies bounded formal/unfiled rows and exact scoped counts."
  @latest """
  SELECT s.* FROM (
    SELECT 'task_event'::text AS source_type,e.id::text AS source_id,e.body,e.created_at
    FROM task_events e WHERE e.task_id=t.id AND e.actor_id=t.assignee_id
      AND e.kind='update' AND e.body IS NOT NULL
      AND e.body NOT LIKE 'agentboard-seat %'
    UNION ALL
    SELECT 'message',m.id::text,m.body,m.created_at FROM messages m
    WHERE m.task_id=t.id AND m.sender_id=t.assignee_id AND m.kind='note'
  ) s ORDER BY s.created_at DESC,s.source_type DESC,s.source_id DESC LIMIT 1
  """
  @unfiled """
  SELECT t.id AS task_id,t.assignee_id AS requester_id,t.pr_url,t.claim_expires_at,t.revision,
    s.source_type,s.source_id,s.body,s.created_at,a.last_heartbeat
  FROM tasks t JOIN agents a ON a.id=t.assignee_id
  JOIN LATERAL (#{@latest}) s ON TRUE
  WHERE t.status NOT IN ('done','cancelled')
    AND s.body ~* '^[[:space:]]*(waiting[[:space:]]+on[[:space:]]+captain|captain[[:space:]]+decision:|captain[[:space:]]+request:)'
    AND NOT EXISTS(SELECT 1 FROM decision_requests d WHERE d.task_id=t.id
      AND (d.status IN ('open','answered') OR
        (d.source_type=s.source_type AND d.source_id=s.source_id)))
  """
  def source(task) do
    case Agentboard.Repo.statement!(@unfiled <> " AND t.id=$1", [task]).rows do
      [] ->
        nil

      [row] ->
        [task_id, owner, pr, lease, revision, type, id, body, at, _] = row

        %{
          "task_id" => task_id,
          "requester_id" => owner,
          "pr_url" => pr,
          "claim_expires_at" => lease,
          "revision" => revision,
          "source_type" => type,
          "source_id" => id,
          "findings" => body,
          "created_at" => at
        }
    end
  end

  def page(filters) when is_map(filters) do
    with {:ok, limit, stale} <- validate(filters),
         {:ok, cursor} <- cursor(filters) do
      scope =
        " AND ($1::text IS NULL OR t.assignee_id=$1) AND ($2::text IS NULL OR t.repo=$2) AND ($3::text IS NULL OR t.id=$3)"

      sql = """
      WITH unfiled AS (#{@unfiled} #{scope}),
      records AS (
        SELECT d.created_at,'decision'::text AS source_type,d.id::text AS source_id,d.status,
          to_jsonb(d)||jsonb_build_object('source_type','decision','source_id',d.id::text,
            'pr_url',t.pr_url,'waiting_seconds',greatest(0,floor(extract(epoch FROM statement_timestamp()-d.created_at))),
            'requester_stale',a.last_heartbeat IS NULL OR a.last_heartbeat <= statement_timestamp()-($4::float8*interval '1 second'),
            'claim_expires_at',t.claim_expires_at,'held_by_decision',board_decision_hold(t.id,t.assignee_id)) AS body
        FROM decision_requests d JOIN tasks t ON t.id=d.task_id JOIN agents a ON a.id=d.requester_id
        WHERE d.status IN ('open','answered') AND t.status NOT IN ('done','cancelled') #{scope}
        UNION ALL
        SELECT u.created_at,u.source_type,u.source_id,'unfiled',
          jsonb_build_object('id',u.source_type||':'||u.source_id,'source_type',u.source_type,
            'source_id',u.source_id,'task_id',u.task_id,'requester_id',u.requester_id,'pr_url',u.pr_url,
            'revision',u.revision,'created_at',u.created_at,'status','unfiled','kind','unfiled',
            'question',left(u.body,8192),'findings',left(u.body,65536),'options','[]'::jsonb,
            'waiting_seconds',greatest(0,floor(extract(epoch FROM statement_timestamp()-u.created_at))),
            'claim_expires_at',u.claim_expires_at,'held_by_decision',false,
            'requester_stale',u.last_heartbeat IS NULL OR u.last_heartbeat <= statement_timestamp()-($4::float8*interval '1 second'))
        FROM unfiled u
      ), waiting_page AS (
        SELECT * FROM records WHERE status<>'answered' AND
          ($5::text IS NULL OR (created_at,source_type,source_id)>
            ($5::text::timestamptz,$6::text,$7::text))
        ORDER BY created_at,source_type,source_id LIMIT #{limit + 1}
      ), answered_page AS (
        SELECT * FROM records WHERE status='answered'
        ORDER BY created_at,source_type,source_id LIMIT 20
      )
      SELECT jsonb_build_object(
        'total',(SELECT count(*) FROM records WHERE status<>'answered'),
        'answered_total',(SELECT count(*) FROM records WHERE status='answered'),
        'decisions',coalesce((SELECT jsonb_agg(body ORDER BY created_at,source_type,source_id) FROM waiting_page),'[]'::jsonb),
        'answered',coalesce((SELECT jsonb_agg(body ORDER BY created_at,source_type,source_id) FROM answered_page),'[]'::jsonb))
      """

      args =
        [filters["owner"], filters["repo"], filters["task"], stale] ++ (cursor || [nil, nil, nil])

      with {:ok, %{rows: [[result]]}} <- Agentboard.Board.query(sql, args, timeout: 2_000) do
        rows = result["decisions"]
        records = Enum.take(rows, limit)
        next = if length(rows) > limit, do: encode(filters, List.last(records))
        {:ok, Map.merge(result, %{"decisions" => records, "next_cursor" => next})}
      end
    end
  end

  def page(_), do: {:error, "invalid_input", "Waiting filters must be an object"}

  defp validate(f) do
    with true <-
           Enum.all?(f, fn {k, v} ->
             k in ~w(owner repo task limit cursor stale_after) and is_binary(v) and
               byte_size(v) <= 4096
           end),
         true <- is_nil(f["owner"]) or Agentboard.Input.slug?(f["owner"]),
         true <- is_nil(f["task"]) or Agentboard.Input.slug?(f["task"]),
         {limit, ""} when limit in 1..100 <- Integer.parse(Map.get(f, "limit", "20")),
         {stale, ""} when stale > 0 and stale <= 31_536_000 <-
           Float.parse(Map.get(f, "stale_after", "600")) do
      {:ok, limit, stale}
    else
      _ -> {:error, "invalid_input", "Invalid waiting filters"}
    end
  end

  defp cursor(%{"cursor" => encoded} = f) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"filters" => hash, "at" => at, "type" => type, "id" => id}} <- Jason.decode(json),
         true <-
           hash == digest(f) and type in ~w(decision task_event message) and is_binary(id) and
             byte_size(id) <= 128,
         {:ok, _, _} <- DateTime.from_iso8601(at) do
      {:ok, [at, type, id]}
    else
      _ -> {:error, "invalid_input", "Cursor does not match this waiting query"}
    end
  end

  defp cursor(_), do: {:ok, nil}

  defp encode(f, r),
    do:
      Jason.encode!(%{
        "filters" => digest(f),
        "at" => r["created_at"],
        "type" => r["source_type"],
        "id" => r["source_id"]
      })
      |> Base.url_encode64(padding: false)

  defp digest(f),
    do:
      :crypto.hash(
        :sha256,
        Jason.encode!(
          f
          |> Map.drop(~w(cursor limit))
          |> Enum.sort()
          |> Enum.map(fn {k, v} -> [k, v] end)
        )
      )
      |> Base.encode16(case: :lower)
end
