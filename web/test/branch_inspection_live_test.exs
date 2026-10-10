defmodule AgentboardWeb.BranchInspectionLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AgentboardWeb.{BranchInspectionComponents, PRLive}

  test "exact endpoints deduplicate only the complete repo/ref/SHA identity" do
    base = relation()

    other = %{
      base
      | id: String.duplicate("b", 64),
        number: "42",
        head_ref: "next",
        head_sha: String.duplicate("d", 40)
    }

    graph = BranchInspectionComponents.graph([base, other])
    assert graph.error == nil
    assert length(graph.nodes) == 3
    assert length(graph.edges) == 2
    fork = %{other | head_repo: "another/repo", head_ref: base.head_ref, head_sha: base.head_sha}
    assert length(BranchInspectionComponents.graph([base, fork]).nodes) == 3
  end

  test "missing, ambiguous and cyclic observations are explicit text-only relationships" do
    base = relation()
    assert BranchInspectionComponents.graph([%{base | head_sha: nil}]).error =~ "unavailable"
    changed = %{base | id: String.duplicate("b", 64), head_sha: String.duplicate("e", 40)}
    assert BranchInspectionComponents.graph([base, changed]).error =~ "different retained SHAs"

    reverse = %{
      base
      | id: String.duplicate("c", 64),
        base_repo: base.head_repo,
        base_ref: base.head_ref,
        base_sha: base.head_sha,
        head_repo: base.base_repo,
        head_ref: base.base_ref,
        head_sha: base.base_sha
    }

    assert BranchInspectionComponents.graph([base, reverse]).error =~ "cycle"
  end

  test "twenty relations have no more than forty endpoints and twenty connectors" do
    relations =
      Enum.map(1..20, fn i ->
        %{relation() | id: to_string(i), base_ref: "base/#{i}", head_ref: "head/#{i}"}
      end)

    graph = BranchInspectionComponents.graph(relations)
    assert length(graph.nodes) == 40
    assert length(graph.edges) == 20
  end

  test "hidden schematic leaves exact full text, fork identity and inspection controls" do
    relation = relation()

    data = %{
      as_of: ~U[2026-10-09 20:00:00Z],
      inspection: nil,
      topology: %{
        relations: [relation],
        total: 1,
        offset: 0,
        error: nil,
        next_cursor: nil,
        previous_cursor: nil
      }
    }

    html =
      render_component(&BranchInspectionComponents.topology/1,
        data: data,
        params: %{"repo" => "fixture/repo"},
        graph_visible: false
      )

    assert html =~ "Default branch unknown"
    assert html =~ "Integration role/health unavailable"
    assert html =~ "Observed base: fixture/repo:release/東京"
    assert html =~ "fork/repo:Feature/東京"
    assert html =~ relation.head_sha
    assert html =~ ~s(aria-haspopup="dialog")
    assert html =~ ~s(data-branch-inspect="#{relation.id}")
    refute html =~ "<svg"
    refute html =~ "healthy"
    assert html =~ "Ahead/behind unavailable"
  end

  test "rejected map repository never interpolates unsafe raw route values" do
    data = %{
      inspection: nil,
      topology: %{
        relations: [],
        total: nil,
        offset: 0,
        error: "Invalid repository",
        previous_cursor: nil,
        next_cursor: nil
      }
    }

    html =
      render_component(&BranchInspectionComponents.topology/1,
        data: data,
        params: %{"repo" => %{"name" => "fixture/repo"}},
        graph_visible: true
      )

    refute html =~ "branch-topology"
  end

  test "glyph is an accessible disclosure and never manufactures numeric divergence" do
    rel = relation()

    html =
      render_component(&BranchInspectionComponents.glyph/1,
        relation: rel,
        selected: %{id: rel.id, mode: "table"}
      )

    assert html =~ ~s(aria-expanded="true")
    assert html =~ ~s(aria-controls="branch-inspection")
    assert html =~ "Ahead/behind unavailable"

    html =
      render_component(&BranchInspectionComponents.glyph/1,
        relation: Map.put(rel, :mergeable_state, "behind"),
        selected: nil
      )

    assert html =~ "Behind base; count unavailable"

    html =
      render_component(&BranchInspectionComponents.glyph/1,
        relation: Map.merge(rel, %{mergeable_state: "behind", fresh: false}),
        selected: nil
      )

    refute html =~ "Behind base; count unavailable"
  end

  test "disabled presentation and stale route/client intents are inert" do
    {:ok, socket} = PRLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    assert {:noreply, ^socket} =
             PRLive.handle_event(
               "inspect_pr",
               %{
                 "id" => relation().id,
                 "mode" => "table",
                 "route_generation" => "0",
                 "client_generation" => "1"
               },
               socket
             )

    socket =
      Phoenix.Component.assign(socket,
        branch_flow: true,
        route_generation: 3,
        client_generation: 5
      )

    assert {:noreply, ^socket} =
             PRLive.handle_event(
               "toggle_branch_graph",
               %{"route_generation" => "2", "client_generation" => "6"},
               socket
             )

    assert {:noreply, ^socket} =
             PRLive.handle_event(
               "toggle_branch_graph",
               %{"route_generation" => "3", "client_generation" => "5"},
               socket
             )

    {:noreply, updated} =
      PRLive.handle_event(
        "toggle_branch_graph",
        %{"route_generation" => "3", "client_generation" => "6"},
        socket
      )

    refute updated.assigns.graph_visible
    assert updated.assigns.client_generation == 6
  end

  test "newer dismissal can close a pending same-PR open without closing a replacement" do
    {:ok, socket} = PRLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    selection = %{id: relation().id, mode: "table"}

    socket =
      Phoenix.Component.assign(socket,
        branch_flow: true,
        selected_inspection: selection,
        inspection_generation: 2,
        client_generation: 1
      )

    params = %{
      "id" => selection.id,
      "mode" => "table",
      "generation" => "1",
      "route_generation" => "0",
      "client_generation" => "2"
    }

    {:noreply, closed} = PRLive.handle_event("close_inspection", params, socket)
    assert closed.assigns.selected_inspection == nil
    assert closed.assigns.inspection_generation == 3

    replacement =
      Phoenix.Component.assign(socket, selected_inspection: %{id: "other", mode: "table"})

    assert {:noreply, ^replacement} = PRLive.handle_event("close_inspection", params, replacement)
  end

  test "shared inspection distinguishes exact provenance, failure and each responsibility" do
    rel =
      Map.merge(relation(), %{
        url: "https://github.com/fixture/repo/pull/41",
        expected_base_sha: String.duplicate("d", 40),
        snapshot_id: "snapshot",
        snapshot_generation: 2,
        poll_generation: 2,
        metadata_available: true
      })

    row = %{
      poll: %{"last_error" => "budget_exhausted"},
      poll_deferral_age: 12,
      worker: nil,
      obligation: %{
        "responsible_id" => "ci-owner",
        "repair_task_id" => "ci-repair",
        "state" => "open",
        "episode" => 3,
        "last_progress_at" => "2026-10-09T19:00:00Z"
      },
      overdue: true,
      rebase_follow_up: %{
        "responsible_id" => "rebase-owner",
        "repair_task_id" => "rebase-repair",
        "resolved_at" => "2026-10-09T19:59:00Z"
      }
    }

    inspection = %{
      id: rel.id,
      mode: "topology",
      relation: rel,
      record: row,
      error: nil,
      detail_path: "/prs/" <> rel.id,
      sources: [
        %{
          "task_id" => "source-task",
          "submitted_by_id" => "submitter",
          "attribution" => "explicit"
        }
      ],
      sources_truncated: true,
      failures: [
        %{
          identity: "failure-1",
          provider_id: "1",
          name: "failed check",
          status: "completed",
          conclusion: "failure",
          source_url: "https://github.com/fixture/repo/actions/runs/1",
          details_url: nil,
          kind: "check",
          latest: true
        }
      ],
      failures_truncated: true
    }

    html =
      render_component(&BranchInspectionComponents.inspection/1,
        inspection: inspection,
        as_of: ~U[2026-10-09 20:00:00Z],
        generation: 2
      )

    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="false")
    assert html =~ "Title not retained"
    assert html =~ "exact source matched"
    assert html =~ "ci-owner"
    assert html =~ "rebase-owner"
    assert html =~ "submitter"
    assert html =~ "Conflict signal resolved; repair completion is explicit"
    assert html =~ "Showing ten failure sources"
    assert html =~ "Showing ten sources"
    assert html =~ "failed check"
    assert html =~ "Latest retained attempt"
    assert html =~ "Poll deferred 12s"
    assert html =~ "2026-10-09 19:00:00 UTC"
    refute html =~ "role=\"alertdialog\""
  end

  test "full initial PR view renders with no selection or read error" do
    relation = relation()

    row = %{
      pr: %{"id" => relation.id, "owner" => "fixture", "repo" => "repo", "number" => "41"},
      poll: nil,
      duplicate_of: nil,
      relation: relation,
      ci_state: "unknown",
      fresh: false,
      poll_deferral_age: 0,
      merge_state: "unknown",
      base_ref: nil,
      obligation: nil,
      rebase_follow_up: nil,
      worker: nil,
      overdue: false,
      decisions: []
    }

    page = %{total: 1, error: nil, previous_cursor: nil, next_cursor: nil, prs: [row]}

    data = %{
      table: page,
      prs: [row],
      inspection: nil,
      topology: nil,
      cards: [],
      ranked_repositories: [],
      inventory_count: 0,
      overflow_count: 0,
      chooser: %{repositories: [], total: 0, previous_cursor: nil, next_cursor: nil},
      attention: %{
        enabled: false,
        oldest: nil,
        total: 0,
        runs: [],
        previous_cursor: nil,
        next_cursor: nil
      },
      as_of: ~U[2026-10-09 20:00:00Z]
    }

    html =
      render_component(&PRLive.render/1,
        data: data,
        error: nil,
        params: %{},
        selected_inspection: nil,
        route_generation: 0,
        inspection_generation: 0,
        client_generation: 0,
        glyphs_visible: true,
        graph_visible: true,
        inspection_notice: nil
      )

    assert html =~ "branch-disclose-"
    refute html =~ "branch-inspection-row"
    assert html =~ "No retained red runs"
  end

  defp relation do
    %{
      id: String.duplicate("a", 64),
      number: "41",
      repository: "fixture/repo",
      base_repo: "fixture/repo",
      base_ref: "release/東京",
      base_sha: String.duplicate("b", 40),
      head_repo: "fork/repo",
      head_ref: "Feature/東京",
      head_sha: String.duplicate("c", 40),
      observed_at: ~U[2026-10-09 19:59:00Z],
      fresh: true,
      ci_state: "unknown",
      merge_state: "mergeable",
      source_currentness_error: nil
    }
  end
end
