defmodule AgentboardWeb.BranchFlowLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AgentboardWeb.{BranchFlowComponents, PRLive}

  test "presentation defaults off and forged events cannot opt in" do
    previous = Application.get_env(:agentboard, :branch_flow_enabled)
    Application.delete_env(:agentboard, :branch_flow_enabled)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:agentboard, :branch_flow_enabled),
        else: Application.put_env(:agentboard, :branch_flow_enabled, previous)
    end)

    {:ok, socket} = PRLive.mount(%{"branch_flow" => "true"}, %{}, %Phoenix.LiveView.Socket{})
    refute socket.assigns.branch_flow
    assert {:noreply, ^socket} = PRLive.handle_event("apply_repository_order", %{}, socket)
    assert {:noreply, ^socket} = PRLive.handle_event("search_prs", %{"q" => "main"}, socket)

    assert {:noreply, ^socket} =
             PRLive.handle_event("search_repositories", %{"chooser_q" => "x"}, socket)
  end

  test "navigation keeps independent attention state and resets only table selection" do
    params = %{
      "repo" => "example/repo",
      "node_kind" => "base",
      "node" => "Feature/東京",
      "q" => "41",
      "show_terminal" => "true",
      "cursor" => "table-cursor",
      "attention_cursor" => "attention-cursor",
      "chooser_q" => "repo"
    }

    path = BranchFlowComponents.repo_path(params, "example/other")
    query = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["repo"] == "example/other"
    assert query["q"] == "41"
    assert query["show_terminal"] == "true"
    assert query["attention_cursor"] == "attention-cursor"
    refute query["cursor"]
    refute query["node"]
    refute query["node_kind"]

    path = BranchFlowComponents.node_path(params, "example/repo", "base", "Feature/東京")
    query = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["node"] == "Feature/東京"
    assert query["node_kind"] == "base"
    assert query["attention_cursor"] == "attention-cursor"
    refute query["cursor"]
    assert path == BranchFlowComponents.node_path(query, "example/repo", "base", "Feature/東京")
  end

  test "global attention retains oldest outside strip, evidence and UTC ages on later pages" do
    oldest = run("outside/tools", "1")

    section = %{
      enabled: false,
      total: 12,
      oldest: oldest,
      runs: [run("other/repo", "12")],
      previous_cursor: "prev",
      next_cursor: nil
    }

    data = %{
      attention: section,
      as_of: ~U[2026-10-09 20:00:00Z],
      cards: [%{repository: "demo/repo"}]
    }

    html =
      render_component(&BranchFlowComponents.attention/1,
        data: data,
        params: %{"repo" => "demo/repo", "attention_cursor" => "page2"},
        degraded: false
      )

    assert html =~ "Oldest retained failure: outside/tools"
    assert html =~ "Outside strip"
    assert html =~ "2026-10-09 19:00:00 UTC"
    assert html =~ "3600s ago"
    assert html =~ "observation disabled"
    assert html =~ "absence of failures does not verify green"
    assert html =~ "12 retained red runs across all repositories"
    assert html =~ "Latest collection deferred: budget_exhausted"
    assert html =~ "source-task"
    assert html =~ "failed job / failed step"
    assert html =~ ~s(id="branch-attention-pagination-previous")
    assert html =~ ~s(id="branch-attention-pagination-reset")
  end

  test "oldest and run data are escaped and empty attention is not green" do
    bad = Map.put(run("<script>alert(1)</script>", "1"), "workflow_name", "<img src=x>")

    data = %{
      attention: %{
        enabled: true,
        total: 1,
        oldest: bad,
        runs: [bad],
        previous_cursor: nil,
        next_cursor: nil
      },
      as_of: ~U[2026-10-09 20:00:00Z],
      cards: []
    }

    html =
      render_component(&BranchFlowComponents.attention/1, data: data, params: %{}, degraded: true)

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    assert html =~ "Last-known attention"
    data = put_in(data.attention, %{data.attention | total: 0, oldest: nil, runs: []})

    html =
      render_component(&BranchFlowComponents.attention/1,
        data: data,
        params: %{},
        degraded: false
      )

    assert html =~ "No retained red runs; current branch health unknown"
    refute html =~ "healthy"
  end

  test "overview is pin-aware, pending features are explicit, and focus order is offered" do
    card = %{
      repository: "fixture/repo",
      available: true,
      open_count: 4,
      unknown_lifecycle_count: 2,
      terminal_count: 1,
      red_count: 0,
      relations: [relation()]
    }

    data = %{
      cards: [card],
      ranked_repositories: ["other/repo"],
      as_of: ~U[2026-10-09 20:00:00Z],
      inventory_count: 7,
      overflow_count: 6,
      chooser: %{repositories: [card], total: 7, previous_cursor: nil, next_cursor: "next"}
    }

    html =
      render_component(&BranchFlowComponents.overview/1,
        data: data,
        params: %{"repo" => "fixture/repo"}
      )

    assert html =~ "eligible captain pins first"
    assert html =~ "Integration intake, default-branch metadata"
    assert html =~ "/settings#branch-flow-settings"
    assert html =~ "Default branch unknown"
    assert html =~ "ahead/behind unavailable"
    assert html =~ "Repository order updated; apply new order"
    assert html =~ ~s(aria-current="page")
    assert html =~ ~s(data-branch-relation="#{relation().id}")
    assert html =~ "fork/repo:Feature/東京"
    assert html =~ "Filter fixture/repo by exact base release/東京"
    assert html =~ "name=\"chooser_q\""
    assert html =~ "phx-hook=\"CompletedCard\""
    assert html =~ "+3 tracked open PRs"
    refute html =~ "Open topology"
  end

  test "unavailable counts stay explicit without fake zeroes or arithmetic" do
    card = %{
      repository: "fixture/repo",
      available: true,
      counts_available: false,
      open_count: nil,
      unknown_lifecycle_count: nil,
      terminal_count: nil,
      red_count: nil,
      relations: [],
      error: "Repository counts unavailable"
    }

    data = %{
      cards: [card],
      ranked_repositories: ["fixture/repo"],
      as_of: ~U[2026-10-09 20:00:00Z],
      inventory_count: nil,
      overflow_count: nil,
      chooser: %{repositories: [card], total: nil, previous_cursor: nil, next_cursor: nil}
    }

    html = render_component(&BranchFlowComponents.overview/1, data: data, params: %{})
    assert html =~ "Repository ranking and counts unavailable"
    assert html =~ "Count unavailable tracked open"
    assert html =~ "Retained red count unavailable; health unknown"
    refute html =~ "0 tracked open"
    refute html =~ "No tracked repositories"
  end

  test "invalid table state is explicit, search is labeled and reset preserves global attention" do
    data = %{table: %{error: "Invalid exact base", total: nil, prs: []}}

    html =
      render_component(&BranchFlowComponents.filters/1,
        data: data,
        params: %{
          "repo" => "fixture/repo",
          "node_kind" => "base",
          "node" => "main",
          "attention_cursor" => "retained"
        }
      )

    assert html =~ "Invalid filters never show an unfiltered table"
    assert html =~ "Clear node filter"
    assert html =~ "Search tracked PR number or branch"
    assert html =~ "Reset table filters"
    assert html =~ "attention_cursor=retained"
    assert html =~ "Show merged/closed"
  end

  test "evidence timestamps use UTC and unknown data stays unavailable" do
    html =
      render_component(&BranchFlowComponents.stamp/1,
        value: "2026-10-09T14:00:00-05:00",
        as_of: ~U[2026-10-09 20:00:00Z]
      )

    assert html =~ "2026-10-09 19:00:00 UTC"
    assert html =~ "3600s ago"
    assert render_component(&BranchFlowComponents.stamp/1, value: nil) =~ "not observed"
  end

  defp relation do
    %{
      id: String.duplicate("a", 64),
      number: "41",
      base_ref: "release/東京",
      head_ref: "Feature/東京",
      head_repo: "fork/repo",
      observed_at: ~U[2026-10-09 19:00:00Z]
    }
  end

  defp run(repository, id) do
    %{
      "id" => repository <> "/" <> id,
      "repository" => repository,
      "branch" => "trunk",
      "workflow_name" => "CI",
      "failed_at" => "2026-10-09T19:00:00Z",
      "observed_at" => "2026-10-09T19:58:00Z",
      "responsible_id" => nil,
      "source_url" => "https://github.com/" <> repository <> "/actions/runs/" <> id,
      "source_tasks" => ["source-task"],
      "run_id" => id,
      "run_attempt" => 2,
      "head_sha" => String.duplicate("b", 40),
      "conclusion" => "failure",
      "last_error" => "budget_exhausted",
      "jobs" => [
        %{
          "name" => "failed job",
          "steps" => ["failed step"],
          "url" => "https://github.com/" <> repository <> "/actions/runs/" <> id
        }
      ]
    }
  end
end
