defmodule Agentboard.DecisionPolicy.Evaluator do
  @moduledoc "Pure, deterministic and fail-closed captain policy evaluation. No I/O or authority checks."
  alias Agentboard.DecisionPolicy.Schema

  @gate ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,255}\/([a-zA-Z0-9][a-zA-Z0-9_.-]{0,127})\z/
  @question_gate ~r/\Aquestion:[a-f0-9]{64}(?::retry:[a-f0-9]{64})?\z/
  @ci ~r/(?:\bci\b|continuous[- ]integration|github[- ]actions|buildbuddy|\bworkflow\b|\b(?:rerun|re-run) (?:the )?checks\b)/iu
  @counts ~w(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty)
  @count_pattern ~r/\b([0-9]+|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|single|a|an)\s+(?:(?:additional|more|new|fresh|full)\s+)?(?:(?:ci|continuous integration|workflow|github actions|buildbuddy)\s+)?(?:runs?|reruns?|re-runs?|builds?|times)\b/iu
  @reverse_count ~r/\b(?:ci|workflow)\s+(?:runs?|reruns?)\s*[:=]\s*([0-9]+)\b/iu
  @verb_count ~r/\b(?:run|rerun|re-run|trigger|execute)\s+([0-9]+|zero|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:ci|workflows?|builds?|checks?)\b/iu
  @ambiguous_ci ~r/\b(?:unlimited|unbounded|multiple|several|unrestricted|couple|dozen|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion)\b|\bas (?:many|often) as\b|\b(?:rerun|re-run|retry|repeat|run)\b.{0,40}\buntil\b|\b(?:then|and|plus|followed by) (?:another|again|one more)\b|\btwice\b|\b(?:twenty)[- ](?:one|two|three|four|five|six|seven|eight|nine)\b/iu
  @negated_guards ~w(--yes merge self-merge force-push rollback secrets secret credentials credential password)
  @guard_phrases [
    "reset --hard",
    "delete branch",
    "drop table",
    "push tag",
    "publish release",
    "deploy to production",
    "rollout to production",
    "production changes",
    "downloads"
  ]

  def evaluate(document, decision, context \\ %{}) do
    case Schema.validate(document) do
      {:ok, _} -> evaluate_valid(document, decision, context)
      {:error, _, _} -> result("escalate", "invalid_policy")
    end
  end

  defp evaluate_valid(_, decision, _) when not is_map(decision),
    do: result("escalate", "invalid_decision")

  defp evaluate_valid(_, _, context) when not is_map(context),
    do: result("escalate", "invalid_context")

  defp evaluate_valid(document, decision, context) do
    cond do
      is_binary(decision["status"]) and decision["status"] != "open" -> result("skip", "not_open")
      context["answered"] == true -> result("skip", "already_answered")
      not valid_context?(context) -> result("escalate", "invalid_context")
      not valid_decision?(decision) -> result("escalate", "invalid_decision")
      true -> evaluate_open(document, decision, context)
    end
  end

  defp evaluate_open(document, decision, context) do
    texts = [decision["question"], Map.get(decision, "findings", "")] ++ decision["options"]
    markers = document["engine"]["captain_marker"]["explicit_markers"]
    captain = Enum.any?(markers, fn marker -> Enum.any?(texts, &contains?(&1, marker)) end)
    hits = escalation_hits(document, texts)

    cond do
      captain ->
        result("escalate", "captain_only")

      hits != [] ->
        result("escalate", "escalate_always", nil, [], hits)

      true ->
        case gate_step(decision) do
          :error -> result("escalate", "unknown_gate")
          {:ok, step} -> choose_rule(document, decision, context, texts, step)
        end
    end
  end

  defp choose_rule(document, decision, context, texts, step) do
    candidates =
      document["rules"]
      |> Enum.flat_map(fn rule ->
        case candidate(rule, decision, texts, step) do
          nil -> []
          score -> [%{"id" => rule["id"], "score" => score, "rule" => rule}]
        end
      end)
      |> Enum.sort_by(&{-&1["score"], &1["id"]})

    public = Enum.map(candidates, &Map.take(&1, ~w(id score)))

    case candidates do
      [] ->
        result("escalate", "no_match", nil, public)

      [%{"score" => score}, %{"score" => score} | _] ->
        result("escalate", "ambiguous_match", nil, public)

      [%{"rule" => rule} | _] ->
        assess_rule(document, decision, context, rule, public, texts, step)
    end
  end

  defp candidate(rule, decision, texts, step) do
    matcher = rule["match"]
    gates = Map.get(matcher, "gate_steps")
    keywords = Map.get(matcher, "keywords_any", [])
    gate_match = not is_nil(gates) and step in gates

    keyword_match =
      Enum.any?(keywords, fn keyword -> Enum.any?(texts, &stem_match?(&1, keyword)) end)

    question_keyword = Enum.any?(keywords, &stem_match?(decision["question"], &1))

    options_matched =
      case matcher["option_match"] do
        nil ->
          0

        pattern ->
          {:ok, regex} = Schema.compile_option_regex(pattern)
          Enum.count(decision["options"], &Regex.match?(regex, &1))
      end

    score = if(gate_match, do: 1, else: 0) + if options_matched == 1, do: 1, else: 0

    if decision["kind"] in matcher["kinds"] and
         (is_nil(gates) or gate_match) and
         (keywords == [] or keyword_match) and
         (is_nil(matcher["option_match"]) or options_matched == 1) and
         (score > 0 or question_keyword), do: score, else: nil
  end

  defp assess_rule(document, decision, context, rule, candidates, texts, step) do
    answer = answer(document, rule)
    hits = escalation_hits(document, [answer])
    ci_runs = Map.get(rule, "ci_runs", 0)
    conditions = Map.get(rule, "conditions", [])

    verify =
      Map.get(rule, "verify_required", false) or
        Enum.any?(conditions, &(is_binary(&1) or &1["type"] == "verification"))

    limits = document["engine"]["limits"]
    ci_reason = ci_reason(decision, rule, texts ++ [answer], step, context, limits)

    cond do
      hits != [] ->
        result("escalate", "escalate_always", rule, candidates, hits)

      Map.get(rule, "manual_only", false) ->
        result("escalate", "manual_only", rule, candidates)

      byte_size(answer) > 8192 ->
        result("escalate", "answer_too_large", rule, candidates)

      verify ->
        result("needs_verification", "verification_required", rule, candidates)
        |> Map.merge(%{"answer" => answer, "ci_runs" => ci_runs})

      not is_nil(ci_reason) ->
        result("escalate", ci_reason, rule, candidates)

      Map.get(context, "answers_used", 0) >= limits["max_auto_answers_per_pr_per_day"] ->
        result("escalate", "answer_budget_exhausted", rule, candidates)

      true ->
        result("match", "rule_matched", rule, candidates)
        |> Map.merge(%{"answer" => answer, "ci_runs" => ci_runs})
    end
  end

  defp ci_reason(decision, rule, texts, step, context, limits) do
    cost = Map.get(rule, "ci_runs", 0)
    requested = decision["requested_ci_runs"]

    related =
      cost > 0 or not is_nil(requested) or Regex.match?(@ci, step || "") or
        Enum.any?(texts, &Regex.match?(@ci, &1))

    cap = limits["max_auto_ci_runs_per_decision"]

    if related do
      cond do
        is_nil(requested) ->
          "ci_request_missing"

        not is_integer(requested) or requested < 0 or requested > 100 ->
          "invalid_ci_request"

        requested > cap or cost > cap ->
          "ci_limit_exceeded"

        requested != cost ->
          "ci_cost_mismatch"

        cost == 0 ->
          "ci_cost_missing"

        Enum.any?(texts, &Regex.match?(@ambiguous_ci, &1)) ->
          "ambiguous_ci_request"

        Enum.any?(texts, fn text -> Enum.any?(text_counts(text), &(&1 != requested)) end) ->
          "ci_request_conflict"

        Enum.any?(texts, &(length(text_counts(&1)) > 1)) ->
          "ambiguous_ci_request"

        Map.get(context, "ci_runs_used", 0) + cost > cap ->
          "ci_budget_exhausted"

        true ->
          nil
      end
    end
  end

  defp text_counts(text) do
    [@count_pattern, @reverse_count, @verb_count]
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text, capture: :all_but_first, return: :index)
    end)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(fn {offset, length} ->
      value = binary_part(text, offset, length)
      normalized = String.downcase(value)

      cond do
        normalized in ["single", "a", "an"] -> 1
        normalized in @counts -> Enum.find_index(@counts, &(&1 == normalized))
        byte_size(normalized) > 3 -> 101
        true -> String.to_integer(normalized)
      end
    end)
  end

  defp answer(document, rule) do
    version = document["metadata"]["version"]
    source = rule["source"]

    prefix =
      "Auto-answered under captain policy v#{version}, rule #{rule["id"]} (source: #{source["ruling"]}, #{source["date"]})."

    custom =
      document["engine"]["answer"]["prefix"]
      |> String.replace("{version}", to_string(version))
      |> String.replace("{rule_id}", rule["id"])
      |> String.replace("{source.ruling}", source["ruling"])
      |> String.replace("{source.date}", source["date"])

    obligations =
      Map.get(rule, "conditions", [])
      |> Enum.filter(&(is_map(&1) and &1["type"] == "obligation"))
      |> Enum.map(&("- " <> &1["text"]))

    sections = [prefix] ++ if(custom == prefix, do: [], else: [custom]) ++ [rule["answer"]]

    sections =
      if obligations == [],
        do: sections,
        else: sections ++ ["Obligations:\n" <> Enum.join(obligations, "\n")]

    Enum.join(sections, "\n\n")
  end

  defp escalation_hits(document, texts) do
    clean = Enum.map(texts, &drop_isolated_guards/1)

    Map.get(document, "escalate_always", [])
    |> Enum.filter(fn escalation ->
      Enum.any?(escalation["keywords"], fn keyword ->
        pattern = "(?<![\\p{L}\\p{N}_])" <> Regex.escape(keyword) <> "(?![\\p{L}\\p{N}_])"
        regex = Regex.compile!(pattern, "iu")
        Enum.any?(clean, &Regex.match?(regex, &1))
      end)
    end)
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  # Only a complete sentence/semicolon-delimited guard list in this closed
  # grammar is ignored. "No merge unless...", questions, quotes and mixed
  # positive/negative clauses remain untouched. Markers are checked earlier.
  defp drop_isolated_guards(text) do
    if Regex.match?(~r/\b(?:unless|except|but|however|provided|until|otherwise)\b/iu, text) do
      text
    else
      text
      |> String.split(~r/[.;](?=\s|$)|\n/u, trim: false)
      |> Enum.map(fn sentence ->
        clauses = String.split(sentence, ",", trim: false)
        if Enum.all?(clauses, &isolated_guard?/1), do: "", else: sentence
      end)
      |> Enum.join(". ")
    end
  end

  defp isolated_guard?(clause) do
    case clause |> String.trim() |> String.downcase() do
      "no " <> action -> action in @negated_guards or action in @guard_phrases
      _ -> false
    end
  end

  # Rule keywords are word-start stems: "regenerat" matches "regeneration",
  # while "ci" does not match "decide" and "merge" does not match "submerge".
  defp stem_match?(text, keyword) do
    regex = Regex.compile!("(?<![\\p{L}\\p{N}_])" <> Regex.escape(keyword), "iu")
    Regex.match?(regex, text)
  end

  defp contains?(text, keyword),
    do: String.contains?(String.downcase(text), String.downcase(keyword))

  defp gate_step(decision) do
    gate = decision["gate_ref"]

    case Regex.run(@gate, gate, capture: :all_but_first) do
      [step] ->
        {:ok, step}

      _ ->
        if(decision["kind"] != "ask_user_gate" and Regex.match?(@question_gate, gate),
          do: {:ok, nil},
          else: :error
        )
    end
  end

  defp valid_context?(context) do
    Map.get(context, "answered", false) in [true, false] and
      Enum.all?(~w(answers_used ci_runs_used), fn key ->
        value = Map.get(context, key, 0)
        is_integer(value) and value >= 0
      end)
  end

  defp valid_decision?(decision) do
    decision["status"] == "open" and
      decision["kind"] in ~w(ask_user_gate approval merge policy credential scope blocked_decision other) and
      bounded_string?(decision["question"], 8192, false) and
      bounded_string?(Map.get(decision, "findings", ""), 65_536, true) and
      bounded_string?(decision["gate_ref"], 512, false) and
      is_list(decision["options"]) and length(decision["options"]) <= 20 and
      Enum.all?(decision["options"], &bounded_string?(&1, 1024, false))
  end

  defp bounded_string?(value, max, empty?) do
    is_binary(value) and String.valid?(value) and byte_size(value) <= max and
      (empty? or byte_size(value) > 0) and not String.contains?(value, <<0>>)
  end

  defp result(outcome, reason, rule \\ nil, candidates \\ [], hits \\ []) do
    %{
      "outcome" => outcome,
      "reason" => reason,
      "rule_id" => if(rule, do: rule["id"], else: nil),
      "answer" => nil,
      "ci_runs" => 0,
      "candidates" => candidates,
      "escalation_hits" => hits
    }
  end
end
