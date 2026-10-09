defmodule AgentboardWeb.SeatScopeLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AgentboardWeb.BoardLive

  setup do
    previous = Application.get_env(:agentboard, :captain_token)
    token = "fixture-seat-scope-captain-0123456789"
    Application.put_env(:agentboard, :captain_token, token)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:agentboard, :captain_token),
        else: Application.put_env(:agentboard, :captain_token, previous)
    end)

    %{captain: Agentboard.Captain.authenticate(token)}
  end

  test "scope summary renders managed gates exactly and distinguishes unmanaged", %{
    captain: captain
  } do
    html = render_component(&BoardLive.seat_scope/1, agent: agent(), captain: captain)
    assert html =~ "Managed"
    assert html =~ "owner/repo"
    assert html =~ "Required labels (all)"
    assert html =~ "Security, Review"
    assert html =~ "Allowed labels (any)"
    assert html =~ "Backend"
    assert html =~ "Additional task labels are allowed"
    assert html =~ "Managed scope alone does not enable automatic claiming"
    assert html =~ "scope-open-worker-a"
    assert html =~ "Revision 3"
    assert html =~ "captain-a"

    unmanaged = Map.put(agent(), "scope", Agentboard.SeatScope.public(nil, "worker-a"))
    html = render_component(&BoardLive.seat_scope/1, agent: unmanaged, captain: nil)
    assert html =~ "Unmanaged"
    assert html =~ "automatic claiming is not authorized"
    refute html =~ "scope-open-worker-a"
    refute html =~ "Allowed repositories"

    scope = Map.merge(agent()["scope"], %{"required_labels" => [], "allowed_labels" => []})
    html = render_component(&BoardLive.seat_scope/1, agent: Map.put(agent(), "scope", scope))
    assert html =~ "No required-label gate"
    assert html =~ "No allowed-label gate"
  end

  test "public and expired sessions cannot forge open, draft or save events", %{captain: captain} do
    for proof <- [
          nil,
          %{"proof" => "forged", "expires" => System.system_time(:second) + 100},
          Map.put(captain, "expires", 0)
        ] do
      socket = socket(proof)

      assert {:noreply, ^socket} =
               BoardLive.handle_event("open_scope", %{"id" => "worker-a"}, socket)

      # Even a pre-existing modal from before expiry does not convey authority.
      socket = Phoenix.Component.assign(socket, scope_form: draft())
      params = Map.merge(fields(), %{"availability_admin" => true, "captain" => true})
      assert {:noreply, ^socket} = BoardLive.handle_event("scope_draft", params, socket)
      assert {:noreply, ^socket} = BoardLive.handle_event("set_scope", params, socket)
    end
  end

  test "scope editing requires an open roster modal for the selected agent", %{captain: captain} do
    socket = socket(captain)
    assert {:noreply, ^socket} = BoardLive.handle_event("set_scope", fields(), socket)

    assert {:noreply, ^socket} =
             BoardLive.handle_event("open_scope", %{"id" => "other-agent"}, socket)

    assert {:noreply, ^socket} = BoardLive.handle_event("open_scope", %{}, socket)

    elsewhere = Phoenix.Component.assign(socket, live_action: :board)

    assert {:noreply, ^elsewhere} =
             BoardLive.handle_event("open_scope", %{"id" => "worker-a"}, elsewhere)
  end

  test "draft changes preserve server-held identity and revision", %{captain: captain} do
    {:noreply, opened} =
      BoardLive.handle_event("open_scope", %{"id" => "worker-a"}, socket(captain))

    assert opened.assigns.scope_form == draft()

    values = Map.merge(fields(), %{"agent_id" => "other-agent", "revision" => "999"})
    {:noreply, edited} = BoardLive.handle_event("scope_draft", values, opened)
    assert edited.assigns.scope_form["agent_id"] == "worker-a"
    assert edited.assigns.scope_form["revision"] == 3
    assert edited.assigns.scope_form["required_labels"] == "Exact Case\n spaced "
    assert edited.assigns.scope_form["allowed_labels"] == ""

    # A newer roster snapshot cannot silently advance a draft's revision.
    updated_agent = put_in(agent(), ["scope", "revision"], 4)
    edited = Phoenix.Component.assign(edited, data: %{"agents" => [updated_agent]})
    {:noreply, edited} = BoardLive.handle_event("scope_draft", fields(), edited)
    assert edited.assigns.scope_form["revision"] == 3

    {:noreply, closed} = BoardLive.handle_event("close_scope", %{}, edited)
    assert closed.assigns.scope_form == nil
    assert closed.assigns.scope_error == nil
    assert {:noreply, ^closed} = BoardLive.handle_event("close_scope", %{}, closed)
    {:noreply, reopened} = BoardLive.handle_event("open_scope", %{"id" => "worker-a"}, closed)
    assert reopened.assigns.scope_form["revision"] == 4
    assert reopened.assigns.scope_form["required_labels"] == "Security, Review"
  end

  test "invalid full replacements retain the captain draft without database writes", %{
    captain: captain
  } do
    {:noreply, socket} =
      BoardLive.handle_event("open_scope", %{"id" => "worker-a"}, socket(captain))

    invalid = Map.put(fields(), "allowed_repos", "")
    {:noreply, rejected} = BoardLive.handle_event("set_scope", invalid, socket)
    assert rejected.assigns.scope_error =~ "nonempty explicit owner/repo"
    assert rejected.assigns.scope_form["required_labels"] == "Exact Case\n spaced "
    assert rejected.assigns.scope_form["allowed_repos"] == ""
    assert rejected.assigns.scope_form["revision"] == 3

    {:noreply, rejected} =
      BoardLive.handle_event("set_scope", Map.put(fields(), "allowed_labels", %{}), socket)

    assert rejected.assigns.scope_error =~ "every scope field as text"
    assert rejected.assigns.scope_form["allowed_labels"] == "Backend"
  end

  test "navigation clears the scope editor and its error", %{captain: captain} do
    socket =
      socket(captain) |> Phoenix.Component.assign(scope_form: draft(), scope_error: "Conflict")

    assert {:noreply, returned} = BoardLive.handle_params(%{"kind" => "all"}, "/agents", socket)
    assert returned.assigns.scope_form == nil
    assert returned.assigns.scope_error == nil
  end

  test "modal exposes close and focus contracts, escaped drafts and immutable revision" do
    form = Map.put(draft(), "allowed_labels", "<script>alert(1)</script>")
    html = render_component(&BoardLive.scope_modal/1, form: form, error: "Draft retained")
    assert html =~ ~s(id="scope-dialog")
    assert html =~ ~s(data-close-event="close_scope")
    assert html =~ ~s(data-return-focus="scope-open-worker-a")
    assert html =~ ~s(phx-submit="set_scope")
    assert html =~ ~s(phx-change="scope_draft")
    assert html =~ ~s(name="allowed_repos")
    assert html =~ ~s(name="required_labels")
    assert html =~ ~s(name="allowed_labels")
    assert html =~ "Expected revision 3"
    assert html =~ "Draft retained"
    assert html =~ ~s(role="alert")
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    refute html =~ ~s(name="revision")
    refute html =~ ~s(name="agent_id")
  end

  defp socket(captain) do
    {:ok, socket} = BoardLive.mount(%{}, %{"captain" => captain}, %Phoenix.LiveView.Socket{})
    Phoenix.Component.assign(socket, live_action: :agents, data: %{"agents" => [agent()]})
  end

  defp agent do
    %{
      "id" => "worker-a",
      "scope" => %{
        "agent_id" => "worker-a",
        "state" => "managed",
        "revision" => 3,
        "allowed_repos" => ["owner/repo"],
        "required_labels" => ["Security, Review"],
        "allowed_labels" => ["Backend"],
        "changed_by" => "captain-a",
        "updated_at" => "2026-10-09T00:00:00Z"
      }
    }
  end

  defp draft do
    %{
      "agent_id" => "worker-a",
      "revision" => 3,
      "allowed_repos" => "owner/repo",
      "required_labels" => "Security, Review",
      "allowed_labels" => "Backend"
    }
  end

  defp fields do
    %{
      "allowed_repos" => "owner/other",
      "required_labels" => "Exact Case\n spaced ",
      "allowed_labels" => ""
    }
  end
end
