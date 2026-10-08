defmodule AgentboardWeb.ContextLiveTest do
  use ExUnit.Case, async: true
  alias AgentboardWeb.ContextLive

  describe "resolve_repo/1" do
    test "known dropdown selection with blank typed repo passes through" do
      assert ContextLive.resolve_repo(%{"repo" => "carverauto/agentboard", "repo_other" => "   "}) ==
               {:ok, %{"repo" => "carverauto/agentboard"}}
    end

    test "known dropdown selection disagreeing with typed repo errors" do
      assert ContextLive.resolve_repo(%{"repo" => "carverauto/agentboard", "repo_other" => "x/y"}) ==
               {:error, "Repository and Other repository disagree; clear one."}
    end

    test "known dropdown selection matching typed repo uses it" do
      assert ContextLive.resolve_repo(%{"repo" => "a/b", "repo_other" => "  a/b  "}) ==
               {:ok, %{"repo" => "a/b"}}
    end

    test "blank dropdown with typed repo resolves to the typed value" do
      assert ContextLive.resolve_repo(%{"repo" => "", "repo_other" => "  c/d  "}) ==
               {:ok, %{"repo" => "c/d"}}
    end

    test "other with typed repo resolves to the typed value" do
      assert ContextLive.resolve_repo(%{"repo" => "other", "repo_other" => "  carverauto/new  "}) ==
               {:ok, %{"repo" => "carverauto/new"}}
    end

    test "other with blank typed repo drops the repo key" do
      assert ContextLive.resolve_repo(%{"repo" => "other", "repo_other" => "   ", "q" => "x"}) ==
               {:ok, %{"q" => "x"}}
    end

    test "other without typed repo drops the repo key" do
      assert ContextLive.resolve_repo(%{"repo" => "other"}) == {:ok, %{}}
    end

    test "missing repo with typed repo resolves to the typed value" do
      assert ContextLive.resolve_repo(%{"q" => "boom", "repo_other" => "x/y"}) ==
               {:ok, %{"q" => "boom", "repo" => "x/y"}}
    end

    test "whitespace-only repo with typed repo resolves to the typed value" do
      assert ContextLive.resolve_repo(%{"repo" => "   ", "repo_other" => "x/y"}) ==
               {:ok, %{"repo" => "x/y"}}
    end

    test "padded other with typed repo resolves to the typed value" do
      assert ContextLive.resolve_repo(%{"repo" => "  other  ", "repo_other" => "x/y"}) ==
               {:ok, %{"repo" => "x/y"}}
    end

    test "whitespace-only repo with blank typed repo drops the repo key" do
      assert ContextLive.resolve_repo(%{"repo" => "   ", "repo_other" => "  "}) == {:ok, %{}}
    end

    test "padded selection with blank typed repo resolves trimmed" do
      assert ContextLive.resolve_repo(%{"repo" => "  a/b  ", "repo_other" => "  "}) ==
               {:ok, %{"repo" => "a/b"}}
    end
  end

  describe "handle_params/3" do
    test "disagreeing repos assign only the param notice" do
      message = "Repository and Other repository disagree; clear one."

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          param_error: nil,
          error: nil,
          filters: %{"repo" => "a/b"},
          data: "old",
          loaded: false,
          live_action: :index
        }
      }

      assert {:noreply, returned} =
               ContextLive.handle_params(%{"repo" => "a/b", "repo_other" => "c/d"}, "/", socket)

      assert returned.assigns.param_error == message
      assert returned.assigns.error == nil
      assert returned.assigns.filters == %{}
      assert returned.assigns.data == nil
    end
  end

  describe "handle_info(:refresh)" do
    test "refresh preserves a param error instead of reloading" do
      message = "Repository and Other repository disagree; clear one."

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          param_error: message,
          error: nil,
          filters: %{},
          data: nil,
          loaded: true,
          live_action: :index
        }
      }

      assert {:noreply, returned} = ContextLive.handle_info(:refresh, socket)
      assert returned.assigns.param_error == message
      assert returned.assigns.error == nil
      assert returned.assigns.data == nil
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
