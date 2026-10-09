defmodule Agentboard.Board do
  use Ash.Domain, backwards_compatible_interface?: false, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(Agentboard.Board.AuditEvent)
    resource(Agentboard.Decisions.Request)
    resource(Agentboard.Decisions.Wake)
    resource(Agentboard.Wake.Intent)
    resource(Agentboard.Wake.Attempt)
    resource(Agentboard.Recovery.Episode)
    resource(Agentboard.Recovery.Attempt)
    resource(Agentboard.Availability.Policy)
    resource(Agentboard.Board.Resources.Agent)
    resource(Agentboard.Board.Resources.Task)
    resource(Agentboard.Board.Resources.TaskEvent)
    resource(Agentboard.Board.Resources.Message)
  end

  alias Agentboard.{Input, Repo}

  # Public domain boundary; mutations use real Ash writes and transactional audit hooks.
  def register(actor, data), do: Agentboard.Board.Operations.register(actor, data)
  def heartbeat(id, actor, data), do: Agentboard.Board.Operations.heartbeat(id, actor, data)
  def retire(id, actor, data), do: Agentboard.Board.Operations.retire(id, actor, data)
  def restore(id, actor, data), do: Agentboard.Board.Operations.restore(id, actor, data)

  def mutate(id, action, actor, data),
    do: Agentboard.Board.Operations.mutate(id, action, actor, data)

  def message(id, actor, data), do: Agentboard.Board.Operations.message(id, actor, data)

  def create(actor, data) do
    with :ok <- Input.task("create", data) do
      id = Map.get_lazy(data, "id", fn -> generated_id(data["title"]) end)
      mutate(id, "create", actor, data)
    end
  end

  def show(resource, id, filters \\ %{})

  def show(resource, id, filters), do: Agentboard.Board.Reads.show(resource, id, filters)

  def count(resource, filters), do: Agentboard.Board.Reads.count(resource, filters)

  def page(resource, filters) when resource != "quota",
    do: Agentboard.Board.Reads.page(resource, filters)

  def page("quota" = resource, filters) do
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

  def snapshot(resource, filters) when resource != "quota",
    do: Agentboard.Board.Reads.snapshot(resource, filters)

  def snapshot("quota" = resource, filters) do
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
    case Repo.statement(sql, params, options) do
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

  defp read_spec("quota", filters), do: Agentboard.Quota.read_spec(filters)
  defp read_spec(_, _), do: {:error, "invalid_input", "Unknown resource"}

  defp predicates(spec, filters) do
    allowed =
      Map.keys(spec.fields) ++
        ~w(limit cursor stale_after) ++ if spec.from == "messages m", do: ["unread"], else: []

    if Enum.any?(Map.keys(filters), &(&1 not in allowed)) or
         (Map.has_key?(filters, "archive") and filters["archive"] not in ~w(active archived)) or
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

  defp valid_cursor?(_, _), do: false

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
