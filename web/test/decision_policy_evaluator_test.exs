defmodule Agentboard.DecisionPolicy.EvaluatorTest do
  use ExUnit.Case, async: true
  alias Agentboard.DecisionPolicy.{Evaluator, Schema}

  defp policy do
    %{
      "apiVersion" => "agentboard/v1alpha1",
      "kind" => "CaptainDecisionPolicy",
      "metadata" => %{"name" => "example-policy", "version" => 1, "status" => "draft"},
      "engine" => %{
        "default_mode" => "dry_run",
        "captain_marker" => %{"explicit_markers" => ["CAPTAIN-ONLY"]},
        "answer" => %{
          "prefix" =>
            "Auto-answered under captain policy v{version}, rule {rule_id} (source: {source.ruling}, {source.date})."
        },
        "limits" => %{
          "max_auto_answers_per_pr_per_day" => 3,
          "max_auto_ci_runs_per_decision" => 1
        }
      },
      "escalate_always" => [
        %{"id" => "merge", "keywords" => ["merge"]},
        %{"id" => "secrets", "keywords" => ["secret", "credential", "api key", "password"]}
      ],
      "rules" => [
        %{
          "id" => "fix-evidence",
          "match" => %{
            "kinds" => ["ask_user_gate"],
            "gate_steps" => ["document", "review"],
            "keywords_any" => ["evidence", "stale", "regenerat"],
            "option_match" => "(?i)^\\s*FIX"
          },
          "answer" => "FIX: regenerate the evidence through the pipeline; never waive it.",
          "source" => %{"ruling" => "Captain chose regenerate over waive", "date" => "2026-01-01"}
        }
      ]
    }
  end

  defp decision do
    %{
      "id" => "decision-1",
      "status" => "open",
      "kind" => "ask_user_gate",
      "gate_ref" => "run-1/review",
      "question" => "Regenerate stale evidence?",
      "findings" => "The screenshot is outdated.",
      "options" => ["FIX: regenerate evidence", "WAIVE: proceed"]
    }
  end

  defp update_rule(document, fun), do: update_in(document["rules"], fn [rule] -> [fun.(rule)] end)

  defp evaluate(document, record \\ decision(), context \\ %{}),
    do: Evaluator.evaluate(document, record, context)

  defp invalid(document), do: assert({:error, "invalid_input", _} = Schema.validate(document))

  test "sample matching returns exact immutable provenance and specificity" do
    assert {:ok, document} = Schema.validate(policy())
    result = evaluate(document)
    assert result["outcome"] == "match"
    assert result["reason"] == "rule_matched"
    assert result["rule_id"] == "fix-evidence"
    assert result["candidates"] == [%{"id" => "fix-evidence", "score" => 2}]

    assert result["answer"] ==
             "Auto-answered under captain policy v1, rule fix-evidence (source: Captain chose regenerate over waive, 2026-01-01).\n\nFIX: regenerate the evidence through the pipeline; never waive it."

    assert result["ci_runs"] == 0
    assert result["escalation_hits"] == []
  end

  test "schema allows the issue145 metadata and all example regexes" do
    document =
      put_in(policy()["metadata"], %{
        "name" => "sample",
        "version" => 12,
        "status" => "approved",
        "approved_by" => "captain",
        "approved_at" => "2026-01-01T00:00:00Z"
      })

    for pattern <- ["(?i)^\\s*FIX", "(?i)approve", "(?i)(authori[sz]e|approve)"] do
      assert {:ok, _} =
               Schema.validate(
                 update_rule(document, &put_in(&1["match"]["option_match"], pattern))
               )
    end
  end

  test "document execution modes are explicit and do not alter pure planning" do
    for server_mode <- ["dry_run", "apply"] do
      p = put_in(policy()["engine"]["server_mode"], server_mode)
      assert {:ok, ^p} = Schema.validate(p)
      assert evaluate(p)["outcome"] == "match"
    end

    invalid(put_in(policy()["engine"]["server_mode"], "enabled"))
    invalid(put_in(policy()["engine"]["default_mode"], "apply"))
  end

  test "only UTC calendar day semantics are allowed" do
    p = put_in(policy()["engine"]["timezone"], "UTC")
    assert {:ok, ^p} = Schema.validate(p)
    invalid(put_in(policy()["engine"]["timezone"], "America/New_York"))
  end

  test "required source ruling and strict calendar date" do
    for source <- [
          nil,
          %{},
          %{"ruling" => "test"},
          %{"date" => "2026-01-01"},
          %{"ruling" => "", "date" => "2026-01-01"},
          %{"ruling" => "test", "date" => "2026-02-30"},
          %{"ruling" => "test", "date" => "2026-1-01"},
          %{"ruling" => "test", "date" => "yesterday"}
        ] do
      invalid(update_rule(policy(), &Map.put(&1, "source", source)))
    end

    invalid(update_rule(policy(), &Map.delete(&1, "source")))
  end

  test "unknown keys rejected at every policy object boundary" do
    bad = [
      Map.put(policy(), "unknown", true),
      put_in(policy()["metadata"]["unknown"], true),
      put_in(policy()["engine"]["unknown"], true),
      put_in(policy()["engine"]["answer"]["unknown"], true),
      put_in(policy()["engine"]["captain_marker"]["unknown"], true),
      put_in(policy()["engine"]["limits"]["unknown"], true),
      update_rule(policy(), &Map.put(&1, "unknown", true)),
      update_rule(policy(), &put_in(&1["match"]["unknown"], true)),
      update_rule(policy(), &put_in(&1["source"]["unknown"], true)),
      update_rule(
        policy(),
        &Map.put(&1, "conditions", [
          %{"type" => "obligation", "text" => "Do it", "unknown" => true}
        ])
      ),
      put_in(policy()["escalate_always"], [
        %{"id" => "guard", "keywords" => ["merge"], "unknown" => true}
      ])
    ]

    Enum.each(bad, &invalid/1)
  end

  test "duplicate ids are rejected within and across rule and guard namespaces" do
    [rule] = policy()["rules"]
    invalid(put_in(policy()["rules"], [rule, rule]))
    invalid(put_in(policy()["escalate_always"], [%{"id" => rule["id"], "keywords" => ["merge"]}]))

    invalid(
      put_in(policy()["escalate_always"], [
        %{"id" => "x", "keywords" => ["a"]},
        %{"id" => "x", "keywords" => ["b"]}
      ])
    )
  end

  test "invalid shape scalar types UTF8 and bounded quantities are rejected" do
    for bad <- [nil, [], "{}", %{metadata: %{}}, %{}, Map.put(policy(), "apiVersion", "v2")] do
      invalid(bad)
    end

    for value <- [-1, 0, 101, "3", 1.5, nil] do
      invalid(put_in(policy()["engine"]["limits"]["max_auto_answers_per_pr_per_day"], value))
    end

    for value <- [-1, 101, "1", nil] do
      invalid(put_in(policy()["engine"]["limits"]["max_auto_ci_runs_per_decision"], value))
    end

    invalid(update_rule(policy(), &Map.put(&1, "manual_only", "true")))
    invalid(update_rule(policy(), &Map.put(&1, "answer", <<255>>)))
    invalid(update_rule(policy(), &Map.put(&1, "answer", "answer\0")))
  end

  test "oversized documents are refused before evaluating" do
    [rule] = policy()["rules"]

    rules =
      Enum.map(
        1..40,
        &Map.merge(rule, %{"id" => "rule-#{&1}", "answer" => String.duplicate("a", 8192)})
      )

    invalid(put_in(policy()["rules"], rules))
    assert Schema.max_bytes() == 262_144
    assert evaluate(put_in(policy()["rules"], rules))["reason"] == "invalid_policy"
  end

  test "regex grammar rejects all unbounded or ambiguous backtracking constructs" do
    for regex <- [
          "(a+)+$",
          "(a|aa)+$",
          "a*",
          "a+",
          "a?",
          "a{1,4}",
          ".*",
          "(?=FIX)",
          "(?<=FIX)",
          "(a)\\1",
          "(?R)",
          "(?i:FIX)",
          "(a(b|c))",
          "(a|b)(c|d)",
          "(a|)",
          "^\\s*.*FIX",
          "\\s*FIX",
          "FIX\\s*",
          "[",
          "[^a]",
          String.duplicate("a", 257)
        ] do
      assert {:error, _} = Schema.compile_option_regex(regex), regex
      invalid(update_rule(policy(), &put_in(&1["match"]["option_match"], regex)))
    end

    for regex <- ["FIX", "(?i)^\\s*FIX", "^FIX$", "(authori[sz]e|approve)", "a\\.b", "[a-z]fixed"] do
      assert {:ok, _} = Schema.compile_option_regex(regex), regex
    end
  end

  test "safe option grammar handles long adversarial nonmatching text" do
    {:ok, regex} = Schema.compile_option_regex("(?i)^\\s*FIX")
    refute Regex.match?(regex, String.duplicate(" ", 65_536) <> "NO")
    {:ok, regex} = Schema.compile_option_regex("(?i)(authori[sz]e|approve)")
    refute Regex.match?(regex, String.duplicate("a", 65_536))
  end

  test "nonopen and already answered identities skip before all matching" do
    for status <- ~w(answered applied withdrawn superseded closed) do
      assert evaluate(policy(), Map.put(decision(), "status", status))["reason"] == "not_open"
    end

    assert evaluate(policy(), decision(), %{"answered" => true})["reason"] == "already_answered"
    assert evaluate(policy(), decision(), %{"answered" => false})["outcome"] == "match"
  end

  test "captain marker is case insensitive and wins even inside negation and findings" do
    for field <- ~w(question findings) do
      result =
        evaluate(
          policy(),
          Map.put(decision(), field, "No captain-only. Regenerate stale evidence.")
        )

      assert result["reason"] == "captain_only"
    end

    assert evaluate(policy(), put_in(decision()["options"], ["FIX captain-only", "WAIVE"]))[
             "reason"
           ] == "captain_only"

    p = put_in(policy()["engine"]["captain_marker"]["explicit_markers"], ["HUMAN-REQUIRED"])

    assert evaluate(p, put_in(decision()["findings"], "HUMAN-REQUIRED"))["reason"] ==
             "captain_only"
  end

  test "escalation beats rules in every source surface and proposed answer" do
    for field <- ~w(question findings) do
      result =
        evaluate(policy(), Map.put(decision(), field, "Please MERGE; regenerate evidence."))

      assert result["reason"] == "escalate_always"
      assert result["escalation_hits"] == ["merge"]
    end

    assert evaluate(policy(), put_in(decision()["options"], ["FIX and merge", "WAIVE"]))["reason"] ==
             "escalate_always"

    p = update_rule(policy(), &Map.put(&1, "answer", "FIX and merge the patch."))
    assert evaluate(p)["reason"] == "escalate_always"
    assert evaluate(p)["answer"] == nil
  end

  test "escalation keywords use Unicode word boundaries not substrings" do
    assert evaluate(
             policy(),
             put_in(decision()["findings"], "emergency merged submergence secretive")
           )["outcome"] == "match"

    assert evaluate(policy(), put_in(decision()["findings"], "émerge secreté"))["outcome"] ==
             "match"

    assert evaluate(policy(), put_in(decision()["findings"], "(merge)"))["reason"] ==
             "escalate_always"
  end

  test "only complete isolated closed-grammar negative guards are ignored" do
    for text <- [
          "No --yes, no merge",
          "No --yes, no merge.",
          "Fix the evidence. No merge; no password."
        ] do
      assert evaluate(policy(), put_in(decision()["findings"], text))["outcome"] == "match", text
    end

    for text <- [
          "No merge unless approved",
          "No merge, but please merge",
          "No merge?",
          "No merge required",
          "No merge.example",
          "No merge. Except if approved",
          "'No merge'",
          "Do not say no merge",
          "No merge, please proceed"
        ] do
      assert evaluate(policy(), put_in(decision()["findings"], text))["reason"] ==
               "escalate_always",
             text
    end
  end

  test "rule keyword stems match only at a word start" do
    p = update_rule(policy(), &put_in(&1["match"]["keywords_any"], ["regenerat"]))
    assert evaluate(p, put_in(decision()["question"], "REGENERATING now?"))["outcome"] == "match"
  end

  test "rule stems do not hit inside unrelated words" do
    for {keyword, question} <- [{"ci", "Please decide"}, {"merge", "Please submerge"}] do
      p = update_rule(policy(), &put_in(&1["match"]["keywords_any"], [keyword]))

      d =
        decision()
        |> Map.put("question", question)
        |> Map.put("findings", "")
        |> Map.put("options", ["FIX", "WAIVE"])

      assert evaluate(p, d)["reason"] == "no_match"
    end
  end

  test "kind and gate constraints must both match" do
    assert evaluate(policy(), put_in(decision()["kind"], "scope"))["reason"] == "no_match"

    assert evaluate(policy(), put_in(decision()["gate_ref"], "run-1/test"))["reason"] ==
             "no_match"
  end

  test "unknown gate structure fails closed without guessed step extraction" do
    for gate <- [
          "review",
          "foo:review",
          "a/b/review",
          "run//review",
          "/review",
          "run/review?yes",
          "run/review/",
          "run/review\n"
        ] do
      assert evaluate(policy(), put_in(decision()["gate_ref"], gate))["reason"] == "unknown_gate",
             gate
    end
  end

  test "specificity chooses the unique most specific rule and top ties escalate" do
    [rule] = policy()["rules"]

    general =
      rule |> Map.put("id", "general") |> update_in(["match"], &Map.delete(&1, "gate_steps"))

    p = put_in(policy()["rules"], [general, rule])
    result = evaluate(p)
    assert result["rule_id"] == "fix-evidence"

    assert result["candidates"] == [
             %{"id" => "fix-evidence", "score" => 2},
             %{"id" => "general", "score" => 1}
           ]

    p = put_in(policy()["rules"], [rule, Map.put(rule, "id", "other")])
    assert evaluate(p)["reason"] == "ambiguous_match"
  end

  test "option_match must select exactly one own option" do
    for options <- [["REVISE", "WAIVE"], ["FIX now", "FIX later"]] do
      assert evaluate(policy(), put_in(decision()["options"], options))["reason"] == "no_match"
    end

    assert evaluate(policy(), put_in(decision()["options"], ["  fIx now", "WAIVE"]))["outcome"] ==
             "match"
  end

  test "zero specificity needs a keyword in the question itself" do
    p =
      update_rule(policy(), fn r ->
        put_in(r["match"], %{"kinds" => ["approval"], "keywords_any" => ["evidence"]})
      end)

    d =
      decision()
      |> Map.put("kind", "approval")
      |> Map.put("gate_ref", "question:" <> String.duplicate("a", 64))

    assert evaluate(p, d)["outcome"] == "match"
    assert evaluate(p, Map.put(d, "question", "Proceed?"))["reason"] == "no_match"
    p = update_rule(p, &update_in(&1["match"], fn m -> Map.delete(m, "keywords_any") end))
    assert evaluate(p, d)["reason"] == "no_match"
  end

  test "unknown conditions can never auto-answer even if context claims verified" do
    conditions = [
      "Uses already-installed tools; no downloads.",
      %{"type" => "verification", "text" => "Verify owned failures"}
    ]

    for condition <- conditions do
      p = update_rule(policy(), &Map.put(&1, "conditions", [condition]))
      result = evaluate(p, decision(), %{"verified" => true})
      assert result["outcome"] == "needs_verification"
      assert is_binary(result["answer"])
    end

    p = update_rule(policy(), &Map.put(&1, "verify_required", true))
    assert evaluate(p)["reason"] == "verification_required"
  end

  test "typed obligations are always written into the exact proposed answer" do
    p =
      update_rule(
        policy(),
        &Map.put(&1, "conditions", [
          %{"type" => "obligation", "text" => "Use only installed tools."}
        ])
      )

    assert evaluate(p)["outcome"] == "match"
    assert String.ends_with?(evaluate(p)["answer"], "Obligations:\n- Use only installed tools.")

    p =
      update_rule(
        p,
        &Map.put(&1, "conditions", [%{"type" => "obligation", "text" => "Please merge"}])
      )

    assert evaluate(p)["reason"] == "escalate_always"
  end

  test "manual rules never auto-answer" do
    p = update_rule(policy(), &Map.put(&1, "manual_only", true))
    assert evaluate(p)["reason"] == "manual_only"
    assert evaluate(p)["answer"] == nil
  end

  test "custom prefix cannot hide required provenance or escalation" do
    p = put_in(policy()["engine"]["answer"]["prefix"], "Team policy says:")
    answer = evaluate(p)["answer"]

    assert String.starts_with?(
             answer,
             "Auto-answered under captain policy v1, rule fix-evidence (source:"
           )

    assert String.contains?(answer, "Team policy says:")
    p = put_in(p["engine"]["answer"]["prefix"], "merge now")
    assert evaluate(p)["reason"] == "escalate_always"
  end

  test "generated answer remains inside the decision answer API limit" do
    p = update_rule(policy(), &Map.put(&1, "answer", String.duplicate("a", 8192)))
    assert evaluate(p)["reason"] == "answer_too_large"
  end

  test "fourth answer reaches the shared PR or task daily cap" do
    assert evaluate(policy(), decision(), %{
             "answers_used" => 2,
             "limit_key" => "pr-1",
             "day" => "2026-01-01"
           })["outcome"] == "match"

    assert evaluate(policy(), decision(), %{"answers_used" => 3})["reason"] ==
             "answer_budget_exhausted"

    assert evaluate(policy(), decision(), %{"answers_used" => 9000})["reason"] ==
             "answer_budget_exhausted"
  end

  defp ci_fixture do
    p =
      update_rule(policy(), fn r ->
        r
        |> Map.put("ci_runs", 1)
        |> Map.put("answer", "APPROVE exactly one CI run.")
        |> Map.put("match", %{
          "kinds" => ["ask_user_gate"],
          "gate_steps" => ["ci"],
          "keywords_any" => ["CI"],
          "option_match" => "(?i)(authori[sz]e|approve)"
        })
      end)

    d =
      decision()
      |> Map.put("gate_ref", "run-1/ci")
      |> Map.put("question", "May I run one CI run?")
      |> Map.put("options", ["AUTHORIZE one CI run", "STOP"])
      |> Map.put("requested_ci_runs", 1)

    {p, d}
  end

  test "CI grant is explicit bounded and retained usage consumes its budget" do
    {p, d} = ci_fixture()
    assert evaluate(p, d)["outcome"] == "match"
    assert evaluate(p, d)["ci_runs"] == 1
    assert evaluate(p, d, %{"ci_runs_used" => 1})["reason"] == "ci_budget_exhausted"
    assert evaluate(p, Map.delete(d, "requested_ci_runs"))["reason"] == "ci_request_missing"
    assert evaluate(p, Map.put(d, "requested_ci_runs", 2))["reason"] == "ci_limit_exceeded"

    assert evaluate(update_rule(p, &Map.put(&1, "ci_runs", 2)), d)["reason"] ==
             "ci_limit_exceeded"

    assert evaluate(update_rule(p, &Map.delete(&1, "ci_runs")), d)["reason"] == "ci_cost_mismatch"
  end

  test "zero declared cost cannot grant CI even when the canonical request is zero" do
    {p, d} = ci_fixture()
    p = update_rule(p, &Map.merge(&1, %{"ci_runs" => 0, "answer" => "APPROVE CI."}))

    d =
      d
      |> Map.put("requested_ci_runs", 0)
      |> Map.put("question", "Approve CI?")
      |> Map.put("options", ["APPROVE", "STOP"])

    assert evaluate(p, d)["reason"] == "ci_cost_missing"
  end

  test "CI related detection includes prose even without a CI gate or cost" do
    d = put_in(decision()["findings"], "Please trigger GitHub Actions after the evidence fix.")
    assert evaluate(policy(), d)["reason"] == "ci_request_missing"
    d = put_in(decision()["findings"], "Please rerun the checks after the evidence fix.")
    assert evaluate(policy(), d)["reason"] == "ci_request_missing"
  end

  test "CI gate detection cannot be bypassed with uppercase or compound step names" do
    for step <- ["CI", "ci-rerun", "continuous-integration"] do
      p = update_rule(policy(), &put_in(&1["match"]["gate_steps"], [step]))
      d = put_in(decision()["gate_ref"], "run-1/" <> step)
      assert evaluate(p, d)["reason"] == "ci_request_missing"
    end
  end

  test "CI freeform numbers never override canonical intent and contradictions escalate" do
    {p, d} = ci_fixture()

    for text <- [
          "May I run two CI runs?",
          "May I run 10 CI runs?",
          "Run two CI checks?",
          "CI runs: 2",
          "Please run CI two times"
        ] do
      assert evaluate(p, Map.put(d, "question", text))["reason"] == "ci_request_conflict", text
    end

    p = update_rule(p, &Map.put(&1, "answer", "APPROVE two CI runs."))
    assert evaluate(p, d)["reason"] == "ci_request_conflict"
  end

  test "unbounded and ambiguous CI requests remain open" do
    {p, d} = ci_fixture()

    for text <- [
          "May I run unlimited CI runs?",
          "Please run CI until green",
          "Run CI twice",
          "Run one CI run then another",
          "Run one CI run and another",
          "Run twenty-one CI runs",
          "Run a couple of CI runs",
          "Run one CI run followed by one CI run"
        ] do
      assert evaluate(p, Map.put(d, "question", text))["reason"] == "ambiguous_ci_request", text
    end
  end

  test "invalid CI request types and negative usage fail closed" do
    {p, d} = ci_fixture()

    for value <- [-1, 101, "1", 1.0, true] do
      assert evaluate(p, Map.put(d, "requested_ci_runs", value))["reason"] == "invalid_ci_request"
    end

    for context <- [
          %{"answers_used" => -1},
          %{"ci_runs_used" => -1},
          %{"answers_used" => "0"},
          %{"answered" => "yes"},
          nil
        ] do
      assert evaluate(p, d, context)["reason"] == "invalid_context"
    end
  end

  test "invalid decision text and shapes do not raise or produce matches" do
    for d <- [
          nil,
          %{},
          put_in(decision()["question"], <<255>>),
          put_in(decision()["options"], "FIX"),
          put_in(decision()["findings"], String.duplicate("a", 65_537)),
          put_in(decision()["question"], "q\0")
        ] do
      assert evaluate(policy(), d)["reason"] == "invalid_decision"
    end
  end

  test "canonical hashes recursively sort objects preserve arrays and distinguish types" do
    left = %{"z" => [%{"b" => 2, "a" => 1}], "a" => "x"}
    right = Enum.into([{"a", "x"}, {"z", [Enum.into([{"a", 1}, {"b", 2}], %{})]}], %{})
    assert Schema.canonical_json(left) == ~s({"a":"x","z":[{"a":1,"b":2}]})
    assert Schema.digest(left) == Schema.digest(right)
    refute Schema.digest([1, 2]) == Schema.digest([2, 1])
    refute Schema.digest(%{"a" => 1}) == Schema.digest(%{"a" => "1"})
    assert String.length(Schema.digest(left)) == 64
  end

  test "plan bytes are stable and candidate ordering independent of policy rule order" do
    [rule] = policy()["rules"]
    other = Map.put(rule, "id", "a-other")
    p = put_in(policy()["rules"], [rule, other])
    expected = p |> evaluate() |> Schema.canonical_json()
    for _ <- 1..20, do: assert(Schema.canonical_json(evaluate(p)) == expected)
    reversed = put_in(p["rules"], [other, rule])
    assert Schema.canonical_json(evaluate(reversed)) == expected
  end
end
