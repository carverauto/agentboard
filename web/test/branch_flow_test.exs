defmodule Agentboard.Delivery.BranchFlowTest do
  use ExUnit.Case, async: true
  alias Agentboard.Delivery.BranchFlow.Route

  test "canonical repository, exact case-sensitive refs and escaped URL round trip" do
    params = %{
      "repo" => "Fixture/REPO",
      "node_kind" => "base",
      "node" => "release/Fix&A",
      "q" => "hotfix"
    }

    assert {:ok, filters} = Route.normalize(params)
    assert filters["repo"] == "fixture/repo"
    assert filters["node"] == "release/Fix&A"
    assert filters["show_terminal"] == "false"
    url = Route.path(filters)
    assert URI.decode_query(URI.parse(url).query) == filters

    assert Route.path(filters, %{"node_kind" => nil, "node" => nil}) ==
             "/prs?q=hotfix&repo=fixture%2Frepo&show_terminal=false"
  end

  test "invalid selections cannot silently broaden to all repositories" do
    for params <- [
          %{"repo" => "fixture"},
          %{"repo" => ["fixture/repo"]},
          %{"repo" => " fixture/repo"},
          %{"repo" => "fixture/repo/extra"},
          %{"node_kind" => "base", "node" => "main"},
          %{"repo" => "fixture/repo", "node_kind" => "pr", "node" => "123"},
          %{
            "repo" => "fixture/repo",
            "node_kind" => "base",
            "node" => String.duplicate("a", 256)
          },
          %{"repo" => "fixture/repo", "node_kind" => "base", "node" => "main\n"},
          %{"repo" => "fixture/repo", "node_kind" => "head", "node" => "main"},
          %{"show_terminal" => "yes"},
          %{"show_terminal" => true},
          %{"q" => []},
          %{"q" => String.duplicate("a", 121)},
          %{"q" => "bad\nquery"}
        ] do
      assert {:error, _} = Route.normalize(params), inspect(params)
    end

    assert {:ok, _} = Route.normalize(%{"q" => String.duplicate("é", 120)})

    assert {:ok, _} =
             Route.normalize(%{
               "repo" => "fixture/repo",
               "node_kind" => "pr",
               "node" => String.duplicate("a", 64)
             })
  end

  test "table cursor is bounded and tied to every table filter" do
    assert {:ok, filters} =
             Route.normalize(%{
               "repo" => "fixture/repo",
               "node_kind" => "base",
               "node" => "main",
               "q" => "42"
             })

    token = Route.cursor("table", 20, filters)
    assert byte_size(token) <= 200
    assert {:ok, 20} = Route.offset(token, "table", filters)
    assert {:ok, 0} = Route.offset(nil, "table", filters)

    for {key, value} <- [
          {"repo", "fixture/other"},
          {"node", "Main"},
          {"node_kind", "pr"},
          {"q", "43"},
          {"show_terminal", "true"}
        ] do
      assert {:error, _} = Route.offset(token, "table", Map.put(filters, key, value))
    end

    assert {:error, _} = Route.offset(token, "chooser", filters)
    assert {:error, _} = Route.offset(token, "attention", filters)
  end

  test "global attention pagination is independent of table filters" do
    token = Route.cursor("attention", 10, %{})

    assert {:ok, 10} =
             Route.offset(token, "attention", %{
               "repo" => "any/repo",
               "q" => "unrelated",
               "show_terminal" => "true"
             })
  end

  test "chooser cursor binds search independently of table route" do
    filters = %{"chooser_q" => "fixture"}
    token = Route.cursor("chooser", 20, filters)
    assert {:ok, 20} = Route.offset(token, "chooser", Map.put(filters, "repo", "other/repo"))
    assert {:error, _} = Route.offset(token, "chooser", %{"chooser_q" => "other"})
  end

  test "malformed, oversized, fractional and section-inappropriate cursors are explicit errors" do
    for token <- [
          false,
          [],
          %{},
          String.duplicate("a", 201),
          "not-a-cursor",
          "e30",
          Route.cursor("table", 1, %{}),
          Route.cursor("table", 2_000_000_020, %{})
        ] do
      assert {:error, _} = Route.offset(token, "table", %{}), inspect(token)
    end

    assert {:error, _} = Route.offset(Route.cursor("attention", 11, %{}), "attention", %{})
  end

  test "path retains rejected scalar filters until explicitly cleared" do
    assert Route.path(%{"repo" => "unknown", "q" => "bad", "unrelated" => "drop"}) ==
             "/prs?q=bad&repo=unknown"

    assert Route.path(%{"repo" => "unknown"}, %{"repo" => nil}) == "/prs"
  end

  test "malformed filter types remain rejected through independent navigation" do
    url = Route.path(%{"repo" => ["fixture/repo"], "q" => []}, %{"attention_cursor" => "next"})
    params = URI.decode_query(URI.parse(url).query)
    assert {:error, _} = Route.normalize(params)
    assert params["attention_cursor"] == "next"
    assert {:error, _} = Route.normalize(Map.delete(params, "repo"))
  end
end
