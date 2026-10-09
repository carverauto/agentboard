defmodule Agentboard.SeatScopeTest do
  use ExUnit.Case, async: true
  alias Agentboard.SeatScope

  defp replacement(overrides \\ %{}) do
    Map.merge(
      %{
        "allowed_repos" => ["fixture/repo"],
        "required_labels" => [],
        "allowed_labels" => [],
        "revision" => 0
      },
      overrides
    )
  end

  describe "canonical_repo/1" do
    test "canonicalizes full repository names without importing an owner alias" do
      assert SeatScope.canonical_repo("Fixture/My.Repo_1-2") == "fixture/my.repo_1-2"
      assert SeatScope.canonical_repo("other/repo") == "other/repo"
      assert SeatScope.canonical_repo("Fixture/.github") == "fixture/.github"
      assert SeatScope.canonical_repo("fixture/_repo") == "fixture/_repo"

      for invalid <- [
            nil,
            1,
            [],
            "",
            "repo",
            "fixture",
            "fixture/",
            "/repo",
            "fixture/repo/extra",
            "https://github.com/fixture/repo",
            "fixture/*",
            "*/repo",
            "fixture/repo*",
            " fixture/repo",
            "fixture/repo ",
            "fixture//repo",
            "fixture/repo\n",
            "fixture/../repo",
            "fixture/.",
            "fixture/.."
          ] do
        assert SeatScope.canonical_repo(invalid) == nil, inspect(invalid)
      end
    end
  end

  describe "validate/1" do
    test "deduplicates and canonicalizes repos while preserving exact labels" do
      assert {:ok, attrs} =
               SeatScope.validate(
                 replacement(%{
                   "allowed_repos" => ["Fixture/REPO", "fixture/repo", "other/repo"],
                   "required_labels" => ["security", "Security", "security"],
                   "allowed_labels" => ["priority:high", "api,cli", "priority:high"],
                   "revision" => 42
                 })
               )

      assert attrs == %{
               allowed_repos: ["fixture/repo", "other/repo"],
               required_labels: ["security", "Security"],
               allowed_labels: ["priority:high", "api,cli"]
             }
    end

    test "requires all replacement fields and rejects privilege or partial update fields" do
      for field <- Map.keys(replacement()) do
        assert {:error, "invalid_input", _} = SeatScope.validate(Map.delete(replacement(), field))
      end

      for field <- ~w(agent_id state changed_by updated_at availability_admin role scope) do
        assert {:error, "invalid_input", _} =
                 SeatScope.validate(Map.put(replacement(), field, "spoofed"))
      end
    end

    test "rejects empty repo gate, wildcards, nulls, nonarrays and invalid revisions" do
      for field <- ~w(allowed_repos required_labels allowed_labels),
          value <- [nil, "fixture/repo", [nil], [1], ["*"], ["security*"]] do
        assert {:error, "invalid_input", _} =
                 SeatScope.validate(Map.put(replacement(), field, value)),
               inspect({field, value})
      end

      for value <- [[], ["repo"], ["fixture/repo", "other/*"]] do
        assert {:error, "invalid_input", _} =
                 SeatScope.validate(replacement(%{"allowed_repos" => value}))
      end

      for value <- [nil, -1, 0.5, "0", true, false] do
        assert {:error, "invalid_input", _} =
                 SeatScope.validate(replacement(%{"revision" => value}))
      end

      for value <- [nil, [], "scope"] do
        assert {:error, "invalid_input", _} = SeatScope.validate(value)
      end
    end

    test "bounds policy entries and labels without truncating them" do
      for field <- ~w(allowed_repos required_labels allowed_labels) do
        assert {:error, "invalid_input", _} =
                 SeatScope.validate(
                   Map.put(replacement(), field, List.duplicate("fixture/repo", 101))
                 )
      end

      for field <- ~w(required_labels allowed_labels),
          value <- [
            "",
            "   ",
            "bad\x00label",
            "two\nlines",
            "tab\tlabel",
            "delete\x7flabel",
            String.duplicate("x", 257)
          ] do
        assert {:error, "invalid_input", _} =
                 SeatScope.validate(Map.put(replacement(), field, [value]))
      end
    end
  end

  describe "task eligibility" do
    test "unmanaged seats retain manual compatibility without automatic claim authority" do
      task = %{repo: nil, labels: []}
      assert SeatScope.matches?(nil, task)
      assert SeatScope.matches?(%{"state" => "unmanaged"}, task)
      refute SeatScope.managed_matches?(nil, task)
      refute SeatScope.managed_matches?(%{"state" => "unmanaged"}, task)
    end

    test "repo gate is an exact full canonical name, independent of label gates" do
      {:ok, scope} = SeatScope.validate(replacement())
      assert SeatScope.matches?(scope, %{repo: "Fixture/REPO", labels: []})
      assert SeatScope.managed_matches?(scope, %{"repo" => "fixture/repo", "labels" => ["extra"]})

      for repo <- [
            nil,
            "repo",
            "other/repo",
            "fixture/repo-other",
            "fixture/repo/child",
            "fixture/*"
          ] do
        refute SeatScope.matches?(scope, %{repo: repo, labels: ["security"]}), inspect(repo)
      end
    end

    test "required labels are all-of; allowed labels are any-of; extra task labels remain valid" do
      {:ok, scope} =
        SeatScope.validate(
          replacement(%{
            "required_labels" => ["security", "backend"],
            "allowed_labels" => ["urgent", "routine"]
          })
        )

      for labels <- [
            ["security", "backend", "urgent"],
            ["routine", "backend", "security", "extra"],
            ["security", "backend", "urgent", "routine"]
          ] do
        assert SeatScope.matches?(scope, %{repo: "fixture/repo", labels: labels})
      end

      for labels <- [
            [],
            ["security", "backend"],
            ["security", "urgent"],
            ["backend", "urgent"],
            ["Security", "backend", "urgent"],
            ["security", "backend", "Urgent"]
          ] do
        refute SeatScope.matches?(scope, %{repo: "fixture/repo", labels: labels}), inspect(labels)
      end

      refute SeatScope.matches?(scope, %{
               repo: "other/repo",
               labels: ["security", "backend", "urgent"]
             })
    end

    test "empty label arrays disable their own gate and string-key public scopes also match" do
      for fields <- [
            %{},
            %{"required_labels" => ["security"]},
            %{"allowed_labels" => ["security"]}
          ] do
        scope = replacement(fields) |> Map.put("state", "managed")

        assert SeatScope.matches?(scope, %{
                 "repo" => "fixture/repo",
                 "labels" => ["security", "other"]
               })
      end
    end
  end
end
