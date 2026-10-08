defmodule AgentboardWeb.ContextLiveTest do
  use ExUnit.Case, async: true
  alias AgentboardWeb.ContextLive

  describe "resolve_repo/1" do
    test "known dropdown selection passes through and drops repo_other" do
      assert ContextLive.resolve_repo(%{"repo" => "carverauto/agentboard", "repo_other" => "x/y"}) ==
               %{"repo" => "carverauto/agentboard"}
    end

    test "other with typed repo resolves to the typed value" do
      assert ContextLive.resolve_repo(%{"repo" => "other", "repo_other" => "  carverauto/new  "}) ==
               %{"repo" => "carverauto/new"}
    end

    test "other with blank typed repo drops the repo key" do
      assert ContextLive.resolve_repo(%{"repo" => "other", "repo_other" => "   ", "q" => "x"}) ==
               %{"q" => "x"}
    end

    test "other without typed repo drops the repo key" do
      assert ContextLive.resolve_repo(%{"repo" => "other"}) == %{}
    end

    test "missing repo leaves other params untouched" do
      assert ContextLive.resolve_repo(%{"q" => "boom", "repo_other" => "x/y"}) == %{"q" => "boom"}
    end
  end

  describe "repo_options/2" do
    setup do
      %{repos: [%{repo: "carverauto/agentboard", entries: 3}, %{repo: "carverauto/serviceradar", entries: 1}]}
    end

    test "known repos render alpha with entry counts", %{repos: repos} do
      assert ContextLive.repo_options(repos, nil) == [
               %{value: "carverauto/agentboard", label: "carverauto/agentboard (3 entries)", selected: false},
               %{value: "carverauto/serviceradar", label: "carverauto/serviceradar (1 entry)", selected: false},
               %{value: "other", label: "Other (type below)…", selected: false}
             ]
    end

    test "current selection is marked", %{repos: repos} do
      options = ContextLive.repo_options(repos, "carverauto/serviceradar")
      assert Enum.find(options, &(&1.value == "carverauto/serviceradar")).selected
      refute Enum.find(options, &(&1.value == "carverauto/agentboard")).selected
    end

    test "unknown selection is prepended so the control still reflects it", %{repos: repos} do
      [first | _] = ContextLive.repo_options(repos, "carverauto/brand-new")
      assert first == %{value: "carverauto/brand-new", label: "carverauto/brand-new", selected: true}
    end

    test "empty known list still offers a first-time path" do
      assert ContextLive.repo_options([], nil) == [
               %{value: "other", label: "Other (type below)…", selected: false}
             ]
    end
  end
end
