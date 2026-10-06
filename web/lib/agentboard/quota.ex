defmodule Agentboard.Quota do
  alias Agentboard.Input

  def push(actor, report) do
    with {:ok, actor} <- Input.actor(actor), :ok <- validate(report) do
      providers =
        Enum.map(report["providers"], fn provider ->
          provider
          |> snake_keys()
          |> Map.put(
            "account_key",
            if(report["schemaVersion"] == 5, do: "default", else: provider["accountKey"])
          )
        end)

      digest = :crypto.hash(:sha256, canonical(report)) |> Base.encode16(case: :lower)

      Agentboard.Evidence.Operations.quota(actor, report, providers, digest)
    end
  end

  def read_spec(filters) do
    case Float.parse(Map.get(filters, "stale_after", "600")) do
      {seconds, ""} ->
        if Agentboard.Input.representable_offset?(seconds) do
          quota_spec(seconds)
        else
          {:error, "invalid_input", "Quota stale threshold must be positive seconds"}
        end

      _ ->
        {:error, "invalid_input", "Quota stale threshold must be positive seconds"}
    end
  end

  defp quota_spec(seconds) do
    seconds = Float.to_string(seconds)

    from = """
    (SELECT DISTINCT ON (o.provider,o.account_key) o.*,r.source_agent_id,r.model,r.harness,r.generated_at,r.ingested_at
    FROM quota_observations o JOIN quota_reports r ON r.id=o.report_id
    ORDER BY o.provider,o.account_key,r.generated_at DESC,r.ingested_at DESC,r.id DESC) q
    """

    json = """
    jsonb_build_object('id',q.id,'report_id',q.report_id,'provider',q.provider,'account_key',q.account_key,
      'source_agent_id',q.source_agent_id,'model',q.model,'harness',q.harness,'generated_at',q.generated_at,'ingested_at',q.ingested_at,
      'observation_stale',q.generated_at < clock_timestamp()-#{seconds}::double precision*interval '1 second',
      'state',q.provider_data->'state','plan',q.provider_data->'plan','account_keys',q.provider_data->'account_keys',
      'quota_semantics',q.provider_data->'quota_semantics',
      'windows',coalesce((SELECT jsonb_agg(w.data ORDER BY w.window_id) FROM quota_windows w WHERE w.observation_id=q.id),'[]'),
      'scopes',coalesce((SELECT jsonb_agg(s.data ORDER BY s.scope) FROM quota_scopes s WHERE s.observation_id=q.id),'[]'))
    """

    {:ok,
     %{
       from: from,
       json: json,
       order: "q.provider ASC,q.account_key ASC",
       sort: ~w(provider account_key),
       fields: %{"provider" => "q.provider", "account" => "q.account_key"}
     }}
  end

  defp validate(%{"schemaVersion" => version, "generatedAt" => stamp, "providers" => providers})
       when version in [5, 6] and is_list(providers) do
    valid = datetime?(stamp) and Enum.all?(providers, &provider?(&1, version))

    identities =
      Enum.map(providers, fn p ->
        if is_map(p),
          do: {p["provider"], if(version == 5, do: "default", else: p["accountKey"])},
          else: nil
      end)

    if valid and length(Enum.uniq(identities)) == length(identities),
      do: :ok,
      else:
        {:error, "invalid_input",
         "Malformed quota report or duplicate provider/account/window/scope"}
  end

  defp validate(_),
    do: {:error, "invalid_input", "Quota requires schemaVersion 5/6, generatedAt, and providers"}

  defp provider?(
         %{
           "provider" => provider,
           "state" => %{"status" => status, "stale" => stale},
           "windows" => windows
         } = p,
         version
       ) do
    Input.text?(provider) and (version == 5 or Input.text?(p["accountKey"])) and
      status in ~w(fresh stale unavailable auth_required rate_limited error) and is_boolean(stale) and
      unique_objects?(windows, "id", &window?/1) and semantics?(p["quotaSemantics"]) and
      optional_strings?(p, "accountKeys") and
      optional_strings?(p["state"], "untrustedWindowIds") and
      optional_datetime?(p["state"], "refreshedAt")
  end

  defp provider?(_, _), do: false

  defp window?(%{"id" => id, "label" => label, "kind" => kind} = w) do
    Input.text?(id) and is_binary(label) and
      kind in ~w(session weekly monthly model credits unknown) and
      optional_percentage?(w, "percentUsed") and optional_percentage?(w, "percentRemaining") and
      optional_datetime?(w, "startsAt") and optional_datetime?(w, "resetsAt") and
      optional_number?(w, "windowSeconds", 0) and optional_number?(w, "spentUsd", 0) and
      optional_number?(w, "limitUsd", 0) and
      (not Map.has_key?(w, "shareOf") or Input.text?(w["shareOf"])) and
      optional_object?(w, "pace")
  end

  defp window?(_), do: false
  defp semantics?(nil), do: true

  defp semantics?(%{"status" => status, "effectiveAvailability" => scopes} = semantics),
    do:
      status in ~w(known partial unknown) and unique_objects?(scopes, "scope", &scope?/1) and
        optional_strings?(semantics, "unresolvedWindowIds")

  defp semantics?(_), do: false

  defp scope?(%{"scope" => scope, "status" => status, "boundedBy" => bounds} = s) do
    Input.text?(scope) and status in ~w(known unknown) and strings?(bounds) and
      optional_percentage?(s, "effectivePercentRemaining") and
      optional_strings?(s, "limitingWindowIds") and
      optional_object?(s, "boundConflict") and optional_object?(s, "pace") and
      runway?(s["runway"]) and selection?(s["selection"])
  end

  defp scope?(_), do: false
  defp runway?(nil), do: true

  defp runway?(%{"status" => status} = r),
    do:
      status in ~w(exhausted_now projected_exhaustion through_reset unknown) and
        optional_number?(r, "usableRunwaySeconds", 0) and
        optional_datetime?(r, "projectedExhaustedAt")

  defp runway?(_), do: false
  defp selection?(nil), do: true

  defp selection?(%{"status" => status} = s),
    do:
      status in ~w(known unknown) and
        (not Map.has_key?(s, "spendPriority") or
           (is_number(s["spendPriority"]) and s["spendPriority"] >= -100 and
              s["spendPriority"] <= 100))

  defp selection?(_), do: false

  defp unique_objects?(items, key, predicate) when is_list(items),
    do: Enum.all?(items, predicate) and length(Enum.uniq_by(items, & &1[key])) == length(items)

  defp unique_objects?(_, _, _), do: false

  defp optional_percentage?(map, key),
    do: not Map.has_key?(map, key) or (is_number(map[key]) and map[key] >= 0 and map[key] <= 100)

  defp optional_number?(map, key, min),
    do: not Map.has_key?(map, key) or (is_number(map[key]) and map[key] >= min)

  defp optional_datetime?(map, key), do: not Map.has_key?(map, key) or datetime?(map[key])
  defp optional_strings?(map, key), do: not Map.has_key?(map, key) or strings?(map[key])
  defp optional_object?(map, key), do: not Map.has_key?(map, key) or is_map(map[key])
  defp strings?(items), do: is_list(items) and Enum.all?(items, &is_binary/1)

  defp datetime?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp datetime?(_), do: false

  # Stable object-key order; array order is part of the report's identity.
  defp canonical(value) when is_map(value),
    do: [
      "{",
      value
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", canonical(v)] end)
      |> Enum.intersperse(","),
      "}"
    ]

  defp canonical(value) when is_list(value),
    do: ["[", Enum.map(value, &canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(value) when is_float(value) and value == trunc(value),
    do: Jason.encode!(trunc(value))

  defp canonical(value), do: Jason.encode!(value)

  defp snake_keys(value) when is_map(value),
    do:
      Map.new(value, fn {key, v} ->
        {key |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2") |> String.downcase(),
         snake_keys(v)}
      end)

  defp snake_keys(value) when is_list(value), do: Enum.map(value, &snake_keys/1)
  defp snake_keys(value), do: value
end

