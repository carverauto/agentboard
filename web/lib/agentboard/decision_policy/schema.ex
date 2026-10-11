defmodule Agentboard.DecisionPolicy.Schema do
  @moduledoc "Strict bounded JSON policy validation and canonical content hashing."

  @max_bytes 262_144
  @identifier ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/
  @kinds ~w(ask_user_gate approval merge policy credential scope blocked_decision other)

  def max_bytes, do: @max_bytes

  def validate(document) do
    try do
      bounded_json!(document, 0)
      require!(byte_size(Jason.encode!(document)) <= @max_bytes, "document exceeds maximum bytes")

      keys!(
        document,
        ~w(apiVersion kind metadata engine rules escalate_always),
        ~w(apiVersion kind metadata engine rules)
      )

      require!(document["apiVersion"] == "agentboard/v1alpha1", "unsupported apiVersion")
      require!(document["kind"] == "CaptainDecisionPolicy", "unsupported policy kind")
      metadata!(document["metadata"])
      engine!(document["engine"])
      rules = list!(document["rules"], 1, 100, "rules")
      escalations = list!(Map.get(document, "escalate_always", []), 0, 50, "escalate_always")
      Enum.each(rules, &rule!/1)
      Enum.each(escalations, &escalation!/1)
      ids = Enum.map(rules ++ escalations, & &1["id"])
      require!(length(Enum.uniq(ids)) == length(ids), "rule and escalation ids must be unique")
      {:ok, document}
    rescue
      _ in [Jason.EncodeError, ArgumentError] -> {:error, "invalid_input", "invalid JSON policy"}
    catch
      {:invalid_policy, message} -> {:error, "invalid_input", message}
    end
  end

  @doc "SHA256 of JSON with recursively sorted object keys; arrays retain their order."
  def digest(value) do
    value
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Stable JSON representation, also useful for reproducible read-only plans."
  def canonical_json(value) when is_map(value) do
    entries = value |> Enum.sort_by(fn {key, _} -> key end)

    contents =
      Enum.map(entries, fn {key, entry} -> [Jason.encode!(key), ":", canonical_json(entry)] end)

    IO.iodata_to_binary(["{", Enum.intersperse(contents, ","), "}"])
  end

  def canonical_json(value) when is_list(value) do
    IO.iodata_to_binary(["[", Enum.intersperse(Enum.map(value, &canonical_json/1), ","), "]"])
  end

  def canonical_json(value), do: Jason.encode!(value)

  @doc """
  Compile the policy's intentionally small, bounded regex grammar.

  Supported: optional leading (?i), anchors, literal text, positive ASCII
  character classes, and at most one flat alternation group (eight branches).
  The only repetition is an optional leading ^\\s*. No nested groups, other
  repetitions, backreferences, lookarounds, wildcards or executable extensions
  are accepted. Consequently matches have a constant bounded number of paths;
  an attacker cannot construct a catastrophic-backtracking policy.
  """
  def compile_option_regex(pattern) when is_binary(pattern) do
    if byte_size(pattern) in 1..256 and String.valid?(pattern) do
      {body, flags} =
        if String.starts_with?(pattern, "(?i)"),
          do: {String.replace_prefix(pattern, "(?i)", ""), "iu"},
          else: {pattern, "u"}

      body = String.replace_prefix(body, "^\\s*", "^")

      if safe_pattern?(body) do
        Regex.compile(pattern_without_flag(pattern), flags)
      else
        {:error, :unsafe_regex}
      end
    else
      {:error, :unsafe_regex}
    end
  end

  def compile_option_regex(_), do: {:error, :unsafe_regex}

  defp pattern_without_flag(pattern), do: String.replace_prefix(pattern, "(?i)", "")

  defp safe_pattern?(body) do
    chars = String.to_charlist(body)
    chars != [] and scan_regex(chars, %{group: false, groups: 0, branches: 1, token: false}, true)
  end

  defp scan_regex([], state, _), do: not state.group and state.token
  defp scan_regex([?^ | rest], state, true), do: scan_regex(rest, state, false)
  defp scan_regex([?$], state, _), do: not state.group and state.token

  defp scan_regex([?\\, char | rest], state, _) when char in ~c".[]()|^$?*+{}\\-" do
    scan_regex(rest, %{state | token: true}, false)
  end

  defp scan_regex([?[ | rest], state, _) do
    {inside, remaining} = Enum.split_while(rest, &(&1 != ?]))

    valid =
      inside != [] and length(inside) <= 64 and
        Enum.all?(inside, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 in [32, ?-, ?_]))

    case remaining do
      [?] | tail] when valid -> scan_regex(tail, %{state | token: true}, false)
      _ -> false
    end
  end

  defp scan_regex([?( | rest], %{groups: 0} = state, _) do
    scan_regex(rest, %{state | group: true, groups: 1, token: false}, false)
  end

  defp scan_regex([?) | rest], %{group: true, token: true} = state, _) do
    scan_regex(rest, %{state | group: false}, false)
  end

  defp scan_regex([?| | rest], %{group: true, token: true, branches: n} = state, _) when n < 8 do
    scan_regex(rest, %{state | branches: n + 1, token: false}, false)
  end

  defp scan_regex([char | _], _, _) when char in ~c"\\[]()|^$?*+{}.", do: false

  defp scan_regex([char | rest], state, _) when char >= 32 do
    scan_regex(rest, %{state | token: true}, false)
  end

  defp scan_regex(_, _, _), do: false

  defp metadata!(metadata) do
    keys!(metadata, ~w(name version status approved_by approved_at), ~w(name version status))
    identifier!(metadata["name"], "metadata.name")
    integer!(metadata["version"], 1, 2_147_483_647, "metadata.version")
    enum!(metadata["status"], ~w(draft approved active), "metadata.status")
    optional!(metadata, "approved_by", &string!(&1, 256, "metadata.approved_by"))

    optional!(metadata, "approved_at", fn value ->
      string!(value, 64, "metadata.approved_at")
      require!(match?({:ok, _, _}, DateTime.from_iso8601(value)), "invalid metadata.approved_at")
    end)
  end

  defp engine!(engine) do
    keys!(
      engine,
      ~w(default_mode server_mode timezone captain_marker answer limits),
      ~w(default_mode captain_marker answer limits)
    )

    require!(engine["default_mode"] == "dry_run", "engine.default_mode must be dry_run")
    optional!(engine, "server_mode", &enum!(&1, ~w(dry_run apply), "engine.server_mode"))
    optional!(engine, "timezone", &require!(&1 == "UTC", "engine.timezone must be UTC"))
    marker = engine["captain_marker"]
    keys!(marker, ~w(explicit_markers), ~w(explicit_markers))
    strings!(marker["explicit_markers"], 1, 20, 128, "captain markers")
    keys!(engine["answer"], ~w(prefix), ~w(prefix))
    string!(engine["answer"]["prefix"], 1024, "answer prefix")
    limits = engine["limits"]

    keys!(
      limits,
      ~w(max_auto_answers_per_pr_per_day max_auto_ci_runs_per_decision),
      ~w(max_auto_answers_per_pr_per_day max_auto_ci_runs_per_decision)
    )

    integer!(limits["max_auto_answers_per_pr_per_day"], 1, 100, "answer limit")
    integer!(limits["max_auto_ci_runs_per_decision"], 0, 100, "CI limit")
  end

  defp rule!(rule) do
    keys!(
      rule,
      ~w(id title match conditions answer rationale source verify_required manual_only ci_runs),
      ~w(id match answer source)
    )

    identifier!(rule["id"], "rule id")
    optional!(rule, "title", &string!(&1, 256, "rule title"))
    optional!(rule, "rationale", &string!(&1, 4096, "rule rationale"))
    string!(rule["answer"], 8192, "rule answer")
    source!(rule["source"])

    optional!(
      rule,
      "verify_required",
      &require!(is_boolean(&1), "verify_required must be boolean")
    )

    optional!(rule, "manual_only", &require!(is_boolean(&1), "manual_only must be boolean"))
    optional!(rule, "ci_runs", &integer!(&1, 0, 100, "rule CI cost"))

    optional!(rule, "conditions", fn conditions ->
      conditions |> list!(0, 20, "conditions") |> Enum.each(&condition!/1)
    end)

    matcher = rule["match"]
    keys!(matcher, ~w(kinds gate_steps keywords_any option_match), ~w(kinds))
    kinds = strings!(matcher["kinds"], 1, length(@kinds), 64, "match kinds")
    Enum.each(kinds, &enum!(&1, @kinds, "match kind"))

    optional!(matcher, "gate_steps", fn steps ->
      steps |> strings!(1, 30, 128, "gate steps") |> Enum.each(&identifier!(&1, "gate step"))
    end)

    optional!(matcher, "keywords_any", &strings!(&1, 1, 50, 256, "match keywords"))

    optional!(matcher, "option_match", fn regex ->
      require!(
        match?({:ok, _}, compile_option_regex(regex)),
        "option_match uses invalid or unsafe regex"
      )
    end)
  end

  defp source!(source) do
    keys!(source, ~w(ruling date), ~w(ruling date))
    string!(source["ruling"], 2048, "source ruling")
    string!(source["date"], 10, "source date")

    require!(
      byte_size(source["date"]) == 10 and match?({:ok, _}, Date.from_iso8601(source["date"])),
      "source date must be an ISO calendar date"
    )
  end

  defp condition!(condition) when is_binary(condition), do: string!(condition, 2048, "condition")

  defp condition!(condition) do
    keys!(condition, ~w(type text), ~w(type text))
    enum!(condition["type"], ~w(obligation verification), "condition type")
    string!(condition["text"], 2048, "condition text")
  end

  defp escalation!(escalation) do
    keys!(escalation, ~w(id keywords), ~w(id keywords))
    identifier!(escalation["id"], "escalation id")
    strings!(escalation["keywords"], 1, 50, 256, "escalation keywords")
  end

  defp keys!(value, allowed, required) do
    require!(is_map(value) and not is_struct(value), "expected JSON object")
    require!(Enum.all?(Map.keys(value), &(&1 in allowed)), "unknown policy key")
    require!(Enum.all?(required, &Map.has_key?(value, &1)), "missing required policy key")
  end

  defp string!(value, max, field) do
    require!(
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        not String.contains?(value, <<0>>) and String.trim(value) != "",
      "invalid " <> field
    )

    value
  end

  defp identifier!(value, field) do
    string!(value, 128, field)
    require!(Regex.match?(@identifier, value), "invalid " <> field)
  end

  defp integer!(value, min, max, field),
    do: require!(is_integer(value) and value >= min and value <= max, "invalid " <> field)

  defp enum!(value, choices, field), do: require!(value in choices, "invalid " <> field)
  defp optional!(map, key, fun), do: if(Map.has_key?(map, key), do: fun.(map[key]))

  defp list!(value, min, max, field) do
    require!(
      is_list(value) and length(value) >= min and length(value) <= max,
      "invalid " <> field
    )

    value
  end

  defp strings!(value, min, max, bytes, field) do
    list!(value, min, max, field)
    Enum.each(value, &string!(&1, bytes, field))
    require!(length(Enum.uniq(value)) == length(value), "duplicate " <> field)
    value
  end

  defp bounded_json!(value, depth), do: bounded_json!(value, depth, @max_bytes)

  # Charge a lower bound on encoded bytes while walking, so oversized decoded
  # values stop before constructing a second huge serialized document.
  defp bounded_json!(value, depth, remaining) do
    require!(depth <= 10, "policy nesting exceeds limit")
    require!(remaining >= 0, "document exceeds maximum bytes")

    left =
      cond do
        is_map(value) and not is_struct(value) ->
          require!(map_size(value) <= 32, "policy object exceeds limit")

          Enum.reduce(value, remaining - 2, fn {key, entry}, budget ->
            require!(is_binary(key) and byte_size(key) <= 128, "invalid JSON object key")
            bounded_json!(entry, depth + 1, budget - byte_size(key) - 3)
          end)

        is_list(value) ->
          require!(length(value) <= 100, "policy array exceeds limit")

          Enum.reduce(value, remaining - 2, fn entry, budget ->
            bounded_json!(entry, depth + 1, budget - 1)
          end)

        is_binary(value) ->
          require!(byte_size(value) <= 65_536 and String.valid?(value), "invalid JSON string")
          remaining - byte_size(value) - 2

        is_number(value) or is_boolean(value) or is_nil(value) ->
          remaining - 1

        true ->
          require!(false, "invalid JSON value")
      end

    require!(left >= 0, "document exceeds maximum bytes")
    left
  end

  defp require!(true, _), do: :ok
  defp require!(_, message), do: throw({:invalid_policy, message})
end
