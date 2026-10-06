defmodule Agentboard.Board do
  alias Agentboard.{Input, Repo}

  # Ordinary module functions: SQL executes in the calling request or LiveView process.
  def register(actor, data) do
    with {:ok, actor} <- Input.actor(actor), :ok <- Input.registration(data) do
      query_one(
        """
        INSERT INTO agents(id,name,model,harness,host,capabilities,metadata)
        VALUES ($1,$2,$3,$4,$5,$6,$7)
        ON CONFLICT(id) DO UPDATE SET model=EXCLUDED.model,
          name=CASE WHEN 'name'=ANY($8) THEN EXCLUDED.name ELSE agents.name END,
          host=CASE WHEN 'host'=ANY($8) THEN EXCLUDED.host ELSE agents.host END,
          capabilities=CASE WHEN 'capabilities'=ANY($8) THEN EXCLUDED.capabilities ELSE agents.capabilities END,
          metadata=CASE WHEN 'metadata'=ANY($8) THEN EXCLUDED.metadata ELSE agents.metadata END,
          updated_at=clock_timestamp() WHERE agents.harness=EXCLUDED.harness
        RETURNING jsonb_build_object('agent',to_jsonb(agents.*))
        """,
        [
          actor["agent"],
          Map.get(data, "name", actor["agent"]),
          actor["model"],
          actor["harness"],
          data["host"],
          Map.get(data, "capabilities", []),
          Map.get(data, "metadata", %{}),
          Map.keys(data)
        ],
        {:error, "conflict", "That agent ID belongs to another harness"}
      )
    end
  end

  def mutate(id, action, actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         :ok <- Input.task(action, data),
         true <- Input.slug?(id) do
      if action == "handoff" do
        query_one("SELECT board_handoff_task($1,$2,$3,$4,$5)", [
          id,
          data,
          actor["agent"],
          actor["model"],
          actor["harness"]
        ])
      else
        query_one("SELECT board_mutate_task($1,$2,$3,$4,$5,$6)", [
          id,
          action,
          data,
          actor["agent"],
          actor["model"],
          actor["harness"]
        ])
      end
    else
      false -> {:error, "invalid_input", "Invalid task ID"}
      error -> error
    end
  end

  def heartbeat(id, actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         true <- id == actor["agent"],
         true <-
           is_map(data) and data["status"] in ~w(busy idle) and
             Enum.all?(data, fn
               {"status", _} -> true
               {"task", v} -> is_nil(v) or Input.slug?(v)
               {"backend", v} -> Input.text?(v)
               _ -> false
             end) do
      query_one("SELECT board_heartbeat($1,$2,$3,$4)", [
        data,
        actor["agent"],
        actor["model"],
        actor["harness"]
      ])
    else
      false -> {:error, "invalid_input", "Invalid heartbeat fields or caller"}
      error -> error
    end
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
             {k, v} when k in ~w(to task) -> Input.slug?(v)
             _ -> false
           end) do
      query_one("SELECT board_message($1,$2,$3,$4,$5)", [
        id,
        data,
        actor["agent"],
        actor["model"],
        actor["harness"]
      ])
    else
      false -> {:error, "invalid_input", "Message requires valid destination and nonempty body"}
      error -> error
    end
  end

  def create(actor, data) do
    with :ok <- Input.task("create", data) do
      id = Map.get_lazy(data, "id", fn -> generated_id(data["title"]) end)
      mutate(id, "create", actor, data)
    end
  end

  def show(resource, id, filters \\ %{})

  def show("tasks", id, filters) do
    with true <- Input.slug?(id),
         {:ok, %{rows: [[task]]}} <-
           query("SELECT #{task_json()} FROM tasks t WHERE t.id=$1", [id], timeout: 2_000),
         {:ok, events} <- page("events", Map.put(filters, "task", id)),
         {:ok, documents} <- Agentboard.Documents.list(id) do
      {:ok,
       %{
         "task" => task,
         "events" => events["events"],
         "next_cursor" => events["next_cursor"],
         "documents" => documents["documents"]
       }}
    else
      false -> {:error, "invalid_input", "Invalid task ID"}
      {:ok, %{rows: []}} -> {:error, "not_found", "Task not found"}
      error -> error
    end
  end

  def show("agents", id, filters) do
    with true <- Input.slug?(id), {:ok, seconds} <- stale_seconds(filters) do
      query_one(
        "SELECT jsonb_build_object('agent', #{agent_json("$2")}) FROM agents a WHERE a.id=$1",
        [id, seconds]
      )
    else
      false -> {:error, "invalid_input", "Invalid agent ID"}
      error -> error
    end
  end

  def page(resource, filters) do
    if Enum.all?(filters, fn {k, v} -> is_binary(k) and is_binary(v) and byte_size(v) <= 4096 end),
       do: do_page(resource, filters),
       else: {:error, "invalid_input", "List filters must be scalar strings"}
  end

  defp do_page(resource, filters) do
    with {:ok, limit} <- limit(filters),
         {:ok, spec} <- read_spec(resource, filters),
         {:ok, where, params} <- predicates(spec, filters),
         {:ok, cursor_where, params} <- cursor(spec, resource, filters, params),
         {:ok, %{rows: rows}} <-
           query(
             "SELECT #{spec.json} FROM #{spec.from} WHERE #{where} #{cursor_where} ORDER BY #{spec.order} LIMIT #{limit + 1}",
             params,
             timeout: 2_000
           ) do
      records = rows |> Enum.map(&hd/1) |> Enum.take(limit)

      next =
        if length(rows) > limit,
          do: encode_cursor(resource, filters, spec, List.last(records)),
          else: nil

      {:ok, %{resource => records, "next_cursor" => next}}
    end
  end

  def snapshot(resource, filters) do
    filters = Map.drop(filters, ~w(limit cursor))

    with true <-
           Enum.all?(filters, fn {k, v} ->
             is_binary(k) and is_binary(v) and byte_size(v) <= 4096
           end),
         {:ok, spec} <- read_spec(resource, filters),
         {:ok, where, params} <- predicates(spec, filters),
         {:ok, %{rows: [[rows]]}} <-
           query(
             "SELECT coalesce(jsonb_agg(record),'[]'::jsonb) FROM (SELECT #{spec.json} AS record FROM #{spec.from} WHERE #{where} ORDER BY #{spec.order}) snapshot",
             params,
             timeout: 2_000
           ) do
      {:ok, %{resource => rows, "next_cursor" => nil}}
    else
      false -> {:error, "invalid_input", "Snapshot filters must be scalar strings"}
      error -> error
    end
  end

  def query(sql, params, options \\ []) do
    case Ecto.Adapters.SQL.query(
           Repo,
           sql,
           params,
           options |> Keyword.put_new(:timeout, 10_000) |> Keyword.put_new(:queue, false)
         ) do
      {:ok, result} ->
        {:ok, result}

      {:error,
       %Postgrex.Error{postgres: %{code: :raise_exception, message: code, detail: detail}}}
      when code in ~w(invalid_input invalid_context not_found conflict) ->
        {:error, code, detail}

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        {:error, "conflict", "That ID already exists"}

      {:error, %Postgrex.Error{postgres: %{code: code}}}
      when code in [
             :check_violation,
             :not_null_violation,
             :foreign_key_violation,
             :invalid_text_representation,
             :numeric_value_out_of_range
           ] ->
        {:error, "invalid_input", "Invalid fields or referenced identity"}

      {:error, _} ->
        {:error, "unavailable", "Board database is unavailable"}
    end
  rescue
    DBConnection.ConnectionError -> {:error, "unavailable", "Board database is unavailable"}
  end

  def query_one(sql, params, missing \\ {:error, "not_found", "Record not found"}) do
    case query(sql, params) do
      {:ok, %{rows: [[value]]}} -> {:ok, value}
      {:ok, %{rows: []}} -> missing
      error -> error
    end
  end

  defp task_json do
    "to_jsonb(t.*) || jsonb_build_object('claim_expired',t.claim_expires_at IS NOT NULL AND t.claim_expires_at <= clock_timestamp())"
  end

  defp agent_json(seconds) do
    "to_jsonb(a.*) || jsonb_build_object('stale',a.last_heartbeat IS NULL OR a.last_heartbeat < clock_timestamp()-#{seconds}::double precision*interval '1 second')"
  end

  defp read_spec("tasks", _),
    do:
      {:ok,
       %{
         from: "tasks t",
         json: task_json(),
         order: "t.priority ASC,t.updated_at DESC,t.id ASC",
         sort: ~w(priority updated_at id),
         fields: %{
           "status" => "t.status",
           "owner" => "t.assignee_id",
           "repo" => "t.repo",
           "label" => "ANY(t.labels)"
         }
       }}

  defp read_spec("agents", filters) do
    with {:ok, seconds} <- stale_seconds(filters) do
      {:ok,
       %{
         from: "agents a",
         json: agent_json(Float.to_string(seconds * 1.0)),
         order: "a.id ASC",
         sort: ["id"],
         fields: %{"harness" => "a.harness", "status" => "a.reported_status"}
       }}
    end
  end

  defp read_spec("events", _),
    do:
      {:ok,
       %{
         from: "task_events e",
         json: "to_jsonb(e.*)",
         order: "e.created_at ASC,e.id ASC",
         sort: ~w(created_at id),
         fields: %{"task" => "e.task_id"}
       }}

  defp read_spec("messages", filters) do
    fields = %{"to" => "m.recipient_id", "task" => "m.task_id"}
    from = "messages m"
    json = "to_jsonb(m.*)"

    {:ok,
     %{
       from: from,
       json: json,
       order: "m.created_at ASC,m.id ASC",
       sort: ~w(created_at id),
       fields: fields,
       unread: filters["unread"] == "true",
       alias: "m"
     }}
  end

  defp read_spec("quota", filters), do: Agentboard.Quota.read_spec(filters)
  defp read_spec(_, _), do: {:error, "invalid_input", "Unknown resource"}

  defp predicates(spec, filters) do
    allowed =
      Map.keys(spec.fields) ++
        ~w(limit cursor stale_after) ++ if spec.from == "messages m", do: ["unread"], else: []

    if Enum.any?(Map.keys(filters), &(&1 not in allowed)) or
         (Map.has_key?(filters, "unread") and filters["unread"] not in ~w(true false)) do
      {:error, "invalid_input", "Unknown list filter"}
    else
      filters
      |> Map.take(Map.keys(spec.fields))
      |> Enum.sort()
      |> Enum.reduce(
        {:ok,
         if(Map.get(spec, :unread, false),
           do: "m.read_at IS NULL AND m.recipient_id IS NOT NULL",
           else: "TRUE"
         ), []},
        fn {key, value}, {:ok, where, params} ->
          {:ok, where <> " AND $#{length(params) + 1}::text = #{spec.fields[key]}",
           params ++ [value]}
        end
      )
    end
  end

  defp cursor(spec, resource, filters, params) do
    case filters["cursor"] do
      nil ->
        {:ok, "", params}

      encoded ->
        with {:ok, json} <- Base.url_decode64(encoded, padding: false),
             {:ok, %{"resource" => ^resource, "filters" => digest, "values" => values}} <-
               Jason.decode(json),
             true <- digest == filter_digest(filters),
             true <- valid_cursor?(spec.sort, values) do
          n = length(params) + 1

          condition =
            case spec.sort do
              ["priority", "updated_at", "id"] ->
                "(t.priority > $#{n} OR (t.priority=$#{n} AND (t.updated_at < $#{n + 1}::text::timestamptz OR (t.updated_at=$#{n + 1}::text::timestamptz AND t.id > $#{n + 2}))))"

              ["id"] ->
                "a.id > $#{n}"

              ["provider", "account_key"] ->
                "(q.provider,q.account_key) > ($#{n},$#{n + 1})"

              ["created_at", "id"] ->
                "(#{Map.get(spec, :alias, "e")}.created_at,#{Map.get(spec, :alias, "e")}.id) > ($#{n}::text::timestamptz,$#{n + 1})"
            end

          {:ok, "AND " <> condition, params ++ values}
        else
          _ -> {:error, "invalid_input", "Cursor does not match this query"}
        end
    end
  end

  defp valid_cursor?(["provider", "account_key"], [provider, account]),
    do: Input.text?(provider) and Input.text?(account)

  defp valid_cursor?(["id"], [id]), do: Input.slug?(id)

  defp valid_cursor?(["priority", "updated_at", "id"], [p, time, id]),
    do: is_integer(p) and p >= 0 and datetime?(time) and Input.slug?(id)

  defp valid_cursor?(["created_at", "id"], [time, id]),
    do: datetime?(time) and is_integer(id) and id > 0

  defp valid_cursor?(_, _), do: false

  defp datetime?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp datetime?(_), do: false

  defp encode_cursor(resource, filters, spec, record) do
    Jason.encode!(%{
      "resource" => resource,
      "filters" => filter_digest(filters),
      "values" => Enum.map(spec.sort, &record[&1])
    })
    |> Base.url_encode64(padding: false)
  end

  defp filter_digest(filters),
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

  defp limit(filters) do
    case Integer.parse(Map.get(filters, "limit", "100")) do
      {n, ""} when n in 1..1000 -> {:ok, n}
      _ -> {:error, "invalid_input", "Page limit must be 1–1000"}
    end
  end

  defp stale_seconds(filters) do
    case parse_float(Map.get(filters, "stale_after", "600")) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "invalid_input", "Stale threshold must be positive seconds"}
    end
  end

  defp parse_float(value) when is_binary(value), do: Float.parse(value)
  defp parse_float(_), do: :error

  defp generated_id(title) do
    base =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 100)

    if(base == "", do: "task", else: base) <>
      "-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end

