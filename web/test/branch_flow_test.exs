defmodule Agentboard.Delivery.BranchFlowTest do
  use ExUnit.Case, async: true
  alias Agentboard.Delivery.BranchFlow.{Relations, Route}

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

  test "topology paging is bound to repo and exact node independently of table search and terminal state" do
    filters = %{"repo" => "fixture/repo", "node_kind" => "base", "node" => "release/Case"}
    token = Route.cursor("topology", 20, filters)
    assert {:ok, 20} = Route.offset(token, "topology", filters)

    assert {:ok, 20} =
             Route.offset(
               token,
               "topology",
               Map.merge(filters, %{
                 "q" => "other",
                 "show_terminal" => "true",
                 "cursor" => "independent",
                 "attention_cursor" => "independent",
                 "view" => "repo"
               })
             )

    for {key, value} <- [{"repo", "fixture/other"}, {"node", "release/case"}, {"node_kind", "pr"}] do
      assert {:error, _} = Route.offset(token, "topology", Map.put(filters, key, value))
    end

    assert {:error, _} = Route.offset(token, "table", filters)
    assert {:error, _} = Route.offset(Route.cursor("topology", 1, filters), "topology", filters)
    path = Route.path(filters, %{"topology_cursor" => token})
    assert URI.decode_query(URI.parse(path).query)["topology_cursor"] == token
  end

  test "one exact source guard requires every snapshot binding with nonnil values" do
    row = source_row()
    assert Relations.source_matches?(row.pr, row.poll, row.snapshot_source)

    for {key, value} <- [
          {:id, "other-snapshot"},
          {:pull_request_id, String.duplicate("b", 64)},
          {:head_sha, String.duplicate("e", 40)},
          {:base_sha, String.duplicate("f", 40)},
          {:generation, 8},
          {:observed_at, ~U[2026-10-09 00:00:01Z]}
        ] do
      refute Relations.source_matches?(row.pr, row.poll, Map.put(row.snapshot_source, key, value))
      refute Relations.source_matches?(row.pr, row.poll, Map.put(row.snapshot_source, key, nil))
    end

    refute Relations.source_matches?(
             row.pr,
             row.poll,
             put_in(row.snapshot_source, [:payload, "base_ref"], "Main")
           )

    refute Relations.source_matches?(
             row.pr,
             Map.put(row.poll, "base_ref", nil),
             row.snapshot_source
           )

    refute Relations.source_matches?(row.pr, row.poll, nil)
    refute Relations.source_matches?(row.pr, nil, row.snapshot_source)

    assert Relations.source_matches?(
             row.pr,
             row.poll,
             Map.put(row.snapshot_source, :observed_at, "2026-10-09T00:00:00+00:00")
           )

    for clause <- [
          "c.id=s.snapshot_id",
          "c.pull_request_id=p.id",
          "c.head_sha=s.head_sha",
          "c.base_sha=s.base_sha",
          "c.observed_at=s.observed_at",
          "c.generation=s.generation",
          "c.payload->>'base_ref'=s.base_ref"
        ] do
      assert Relations.matched_sql() =~ clause
    end
  end

  test "qualified relations preserve exact fork endpoints and authoritative expected base" do
    row = source_row() |> Relations.qualify()
    assert row.fresh
    assert row.ci_state == "passing"
    assert row.relation.metadata_available
    assert row.relation.head_repo == "fork/repo"
    assert row.relation.head_ref == "feature/Case"
    assert row.relation.base_repo == "fixture/repo"
    assert row.relation.base_ref == "main"
    assert row.relation.expected_base_sha == String.duplicate("d", 40)
    assert row.relation.numeric_divergence == nil
    assert row.relation.title == nil
    assert row.relation.off_page_parent == nil
    assert row.source_currentness_error == nil
    refute Map.has_key?(row, :snapshot_source)
  end

  test "mismatched proof cannot display green or mergeable but retains failing red" do
    passing = source_row() |> put_in([:snapshot_source, :generation], 2) |> Relations.qualify()
    refute passing.fresh
    assert passing.ci_state == "unknown"
    assert passing.merge_state == "unknown"
    assert passing.mergeable == nil
    refute passing.relation.metadata_available
    assert passing.relation.head_repo == nil
    assert passing.relation.head_ref == nil
    assert passing.relation.head_sha == nil
    assert passing.relation.base_ref == nil
    assert passing.relation.base_sha == nil
    assert is_binary(passing.source_currentness_error)

    failing = source_row() |> put_in([:poll, "ci_state"], "failing")
    stale = failing |> Map.merge(%{ci_state: "stale", fresh: false}) |> Relations.qualify()
    assert stale.ci_state == "failing"
    refute stale.fresh
    assert stale.relation.metadata_available

    mismatched = failing |> put_in([:snapshot_source, :generation], 2) |> Relations.qualify()
    assert mismatched.ci_state == "failing"
    refute mismatched.fresh
    assert is_binary(mismatched.source_currentness_error)
  end

  test "the shared guard never upgrades authoritative stale or policy unknown observations" do
    for state <- ["stale", "unknown"] do
      row =
        source_row()
        |> Map.merge(%{ci_state: state, fresh: false, merge_state: "stale"})
        |> Relations.qualify()

      assert row.ci_state == state
      refute row.fresh
      assert row.merge_state == "stale"
      assert row.relation.expected_base_sha == String.duplicate("d", 40)
    end
  end

  defp source_row do
    id = String.duplicate("a", 64)
    head = String.duplicate("a", 40)
    base = String.duplicate("b", 40)
    snapshot_id = "f1ab5de4-304d-4a2b-ab6a-5193f63fca96"
    observed = ~U[2026-10-09 00:00:00Z]

    %{
      pr: %{
        "id" => id,
        "owner" => "fixture",
        "repo" => "repo",
        "number" => "42",
        "url" => "https://github.com/fixture/repo/pull/42"
      },
      poll: %{
        "snapshot_id" => snapshot_id,
        "head_sha" => head,
        "base_sha" => base,
        "generation" => 7,
        "observed_at" => "2026-10-09T00:00:00Z",
        "base_ref" => "main",
        "ci_state" => "passing",
        "lifecycle" => "open",
        "last_error" => nil
      },
      snapshot_source: %{
        id: snapshot_id,
        pull_request_id: id,
        head_sha: head,
        base_sha: base,
        generation: 7,
        observed_at: observed,
        payload: %{"base_ref" => "main", "head_ref" => "feature/Case", "head_repo" => "fork/repo"}
      },
      ci_state: "passing",
      fresh: true,
      observed_at: observed,
      expected_base_sha: String.duplicate("d", 40),
      merge_state: "mergeable",
      mergeable: true,
      mergeable_state: "clean",
      draft: false,
      base_ref: "main"
    }
  end
end
