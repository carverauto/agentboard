defmodule Agentboard.RosterTest do
  use ExUnit.Case, async: true

  describe "Input.registration/1 kind allowlist" do
    test "accepts each identity kind" do
      for kind <- ~w(seat human system fixture) do
        assert :ok = Agentboard.Input.registration(%{"kind" => kind})
      end
    end

    test "rejects unknown kinds and other junk" do
      assert {:error, "invalid_input", _} = Agentboard.Input.registration(%{"kind" => "bot"})
      assert {:error, "invalid_input", _} = Agentboard.Input.registration(%{"kind" => ""})
      assert {:error, "invalid_input", _} = Agentboard.Input.registration(%{"kind" => nil})
    end
  end

  describe "Board.Reads.roster_threshold/0" do
    setup do
      previous = Application.get_env(:agentboard, :roster)
      on_exit(fn -> Application.put_env(:agentboard, :roster, previous) end)
      :ok
    end

    test "defaults to 20 minutes" do
      Application.delete_env(:agentboard, :roster)
      assert {:ok, 1200.0} = Agentboard.Board.Reads.roster_threshold()
    end

    test "honors minute and second forms" do
      Application.put_env(:agentboard, :roster, stale_after: "10m")
      assert {:ok, 600.0} = Agentboard.Board.Reads.roster_threshold()

      Application.put_env(:agentboard, :roster, stale_after: "90")
      assert {:ok, 90.0} = Agentboard.Board.Reads.roster_threshold()
    end

    test "rejects garbage config instead of silently mis-staling" do
      Application.put_env(:agentboard, :roster, stale_after: "soon")
      assert {:error, "invalid_input", _} = Agentboard.Board.Reads.roster_threshold()
    end
  end

  describe "Operations.retire/3 reason validation" do
    @admin %{
      "agent" => "captain",
      "model" => "human",
      "harness" => "captain",
      availability_admin: true
    }

    test "empty body returns invalid_input instead of raising" do
      assert {:error, "invalid_input", _} =
               Agentboard.Board.Operations.retire("worker-a", @admin, %{})
    end

    test "force-only body without a reason returns invalid_input" do
      assert {:error, "invalid_input", _} =
               Agentboard.Board.Operations.retire("worker-a", @admin, %{"force" => true})
    end

    test "blank reason returns invalid_input" do
      assert {:error, "invalid_input", _} =
               Agentboard.Board.Operations.retire("worker-a", @admin, %{"reason" => "   "})
    end
  end
end

defmodule AgentboardWeb.AgentIdentityTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AgentboardWeb.BoardLive

  test "identity links keep full selectable IDs and exact encoded owner filters" do
    for id <- [
          "agent-a",
          "codex-agent-a-server",
          "custom-repo_with_underscores-role",
          String.duplicate("x", 128)
        ] do
      for archived <- [false, true] do
        html = render_component(&BoardLive.agent_identity/1, id: id, archived: archived)
        path = if archived, do: "/archive", else: "/"
        assert html =~ ~s(href="#{path}?owner=#{URI.encode_www_form(id)}")
        assert html =~ ~s(aria-label="View tasks owned by #{id}")
        assert html =~ ~s(<code class="select-all [overflow-wrap:anywhere]">#{id}</code>)
      end
    end
  end

  test "identity output escapes markup and encodes query metacharacters defensively" do
    id = ~s(worker&repo=<script>"#)
    html = render_component(&BoardLive.agent_identity/1, id: id)
    assert html =~ ~s(href="/?owner=worker%26repo%3D%3Cscript%3E%22%23")
    assert html =~ "worker&amp;repo=&lt;script&gt;&quot;#"
    refute html =~ "<script>"
  end

  test "unassigned tasks have no invented owner link" do
    html = render_component(&BoardLive.agent_identity/1, id: nil)
    assert html =~ "Unassigned"
    refute html =~ "<a"
    refute html =~ "owner="
  end

  test "roster keeps friendly names separate from full linked board identities" do
    id = "codex-repo_with_underscores-agent-a"

    agent = %{
      "id" => id,
      "name" => "Friendly worker",
      "harness" => "codex",
      "kind" => "seat",
      "stale" => false,
      "availability" => %{"state" => "active"},
      "capabilities" => [],
      "scope" => Agentboard.SeatScope.public(nil, id)
    }

    html = render_page(:agents, %{"agents" => [agent], "roster_stale_after" => 1200})
    assert html =~ "<strong>Friendly worker</strong>"
    assert html =~ ~s(href="/?owner=#{id}")
    assert html =~ ~s(>#{id}</code>)
    assert html =~ "Unmanaged"
  end

  test "open, completed and archived cards and task detail use the full owner" do
    id = "codex-agent-a-server"

    for status <- ["in_progress", "done"], view <- [:board, :archive] do
      task = %{
        "id" => "task-one",
        "title" => "Fixture task",
        "status" => status,
        "assignee_id" => id,
        "priority" => 3
      }

      data = %{
        "columns" => %{status => %{"total" => 1, "page" => 1, "tasks" => [task]}},
        "roster" => %{}
      }

      html = render_page(view, data)
      path = if view == :archive and status == "done", do: "/archive", else: "/"
      assert html =~ ~s(href="#{path}?owner=#{id}")
      assert html =~ ~s(>#{id}</code>)
    end

    for archived_at <- [nil, "2026-10-09T00:00:00Z"] do
      data = %{
        "task" => %{"id" => "task-one", "status" => "done", "assignee_id" => id},
        "archive" => %{"archived_at" => archived_at},
        "roster" => %{},
        "events" => [],
        "documents" => [],
        "messages" => []
      }

      html = render_page(:task, data)
      path = if archived_at, do: "/archive", else: "/"
      assert html =~ ~s(href="#{path}?owner=#{id}")
      assert html =~ ~s(>#{id}</code>)
    end
  end

  defp render_page(view, data) do
    {:ok, socket} = BoardLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    socket = Phoenix.Component.assign(socket, live_action: view, loaded: true, data: data)
    render_component(&BoardLive.render/1, Map.to_list(Map.put(socket.assigns, :flash, %{})))
  end
end
