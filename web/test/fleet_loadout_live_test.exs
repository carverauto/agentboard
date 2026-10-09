defmodule AgentboardWeb.FleetLoadoutLiveTest.Service do
  def show(id, capability), do: call(:show, [id, capability])
  def replace(id, capability, data), do: call(:replace, [id, capability, data])

  defp call(operation, args) do
    send(self(), {:fleet_call, operation, args})
    [response | rest] = Process.get({__MODULE__, operation}, [])
    Process.put({__MODULE__, operation}, rest)

    case response do
      :raise -> raise "Simulated lost connection"
      :exit -> exit(:timeout)
      response -> response
    end
  end
end

defmodule AgentboardWeb.FleetLoadoutLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AgentboardWeb.SettingsLive
  alias AgentboardWeb.FleetLoadoutLiveTest.Service

  setup do
    previous_token = Application.get_env(:agentboard, :captain_token)
    previous_service = Application.get_env(:agentboard, :fleet_loadout_service)
    token = "fixture-fleet-loadout-captain-0123456789"
    Application.put_env(:agentboard, :captain_token, token)
    Application.put_env(:agentboard, :fleet_loadout_service, Service)

    on_exit(fn ->
      restore(:captain_token, previous_token)
      restore(:fleet_loadout_service, previous_service)
    end)

    %{captain: Agentboard.Captain.authenticate(token)}
  end

  test "public, forged, and expired capabilities cannot read, draft, save, retry or reload", %{
    captain: captain
  } do
    opened = open(captain)

    for capability <- [
          nil,
          %{"proof" => "forged", "expires" => System.system_time(:second) + 100},
          Map.put(captain, "expires", 0)
        ],
        event <- ~w(open_fleet fleet_draft save_fleet retry_fleet reload_fleet close_fleet) do
      socket = Phoenix.Component.assign(opened, capability: capability)

      params = %{
        "fleet_id" => "fleet-a",
        "seats_json" => Jason.encode!([seat()]),
        "captain" => captain,
        "availability_admin" => true
      }

      assert {:noreply, rejected} = SettingsLive.handle_event(event, params, socket)
      assert rejected.assigns.fleet_form == nil
      assert rejected.assigns.fleet_error =~ "Captain access required"
      refute_received {:fleet_call, _, _}
    end
  end

  test "a real capability is rechecked after token rotation", %{captain: captain} do
    opened = open(captain)
    Application.put_env(:agentboard, :captain_token, "replacement-fleet-captain-0123456789")
    {:noreply, rejected} = SettingsLive.handle_event("save_fleet", fields(), opened)
    assert rejected.assigns.fleet_form == nil
    refute_received {:fleet_call, _, _}
  end

  test "a named fleet must be explicitly opened and cannot change under a pending draft", %{
    captain: captain
  } do
    closed = socket(captain)

    for event <- ~w(fleet_draft save_fleet retry_fleet reload_fleet) do
      assert {:noreply, ^closed} = SettingsLive.handle_event(event, fields(), closed)
    end

    for params <- [%{}, %{"fleet_id" => []}, %{"fleet_id" => "../bad"}] do
      {:noreply, rejected} = SettingsLive.handle_event("open_fleet", params, closed)
      assert rejected.assigns.fleet_form == nil
    end

    refute_received {:fleet_call, _, _}
    opened = open(captain)

    {:noreply, unchanged} =
      SettingsLive.handle_event("open_fleet", %{"fleet_id" => "fleet-b"}, opened)

    assert unchanged.assigns.fleet_form == opened.assigns.fleet_form
    assert unchanged.assigns.fleet_error =~ "Dismiss this editor"
    refute_received {:fleet_call, _, _}
  end

  test "draft and save cannot forge fleet identity, revision or idempotency key", %{
    captain: captain
  } do
    opened = open(captain)
    form = opened.assigns.fleet_form

    for key <- ~w(fleet_id revision idempotency_key enabled captain loadout) do
      forged = Map.put(fields(), key, "forged")

      for event <- ~w(fleet_draft save_fleet) do
        {:noreply, rejected} = SettingsLive.handle_event(event, forged, opened)
        assert rejected.assigns.fleet_form == form
        assert rejected.assigns.fleet_error =~ "server-held"
        refute_received {:fleet_call, _, _}
      end
    end

    text = Jason.encode!([Map.put(seat(), "desired_model", "next-model")])

    {:noreply, edited} =
      SettingsLive.handle_event(
        "fleet_draft",
        %{"seats_json" => text, "_target" => ["seats_json"]},
        opened
      )

    assert edited.assigns.fleet_form.id == "fleet-a"
    assert edited.assigns.fleet_form.revision == 3
    assert edited.assigns.fleet_form.idempotency_key == form.idempotency_key
    assert edited.assigns.fleet_form.seats_json == text
    refute_received {:fleet_call, _, _}
  end

  test "malformed, oversized and invalid replacements retain drafts without writes", %{
    captain: captain
  } do
    opened = open(captain)

    invalid_seats = [
      [%{}],
      [Map.put(seat(), "enabled", true)],
      [Map.put(seat(), "scope", %{"revision" => 1})],
      [Map.put(seat(), "scope_revision", -1)],
      [Map.put(seat(), "desired_model", "   ")],
      List.duplicate(seat(), 33)
    ]

    for text <- ["{", "null", "{}"] ++ Enum.map(invalid_seats, &Jason.encode!/1) do
      {:noreply, rejected} =
        SettingsLive.handle_event("save_fleet", %{"seats_json" => text}, opened)

      assert is_binary(rejected.assigns.fleet_error)
      assert rejected.assigns.fleet_form.seats_json == text
      assert rejected.assigns.fleet_form.revision == 3
      assert rejected.assigns.fleet_form.state == :editing
      refute_received {:fleet_call, _, _}
    end

    for params <- [%{}, %{"seats_json" => %{}}, %{"seats_json" => String.duplicate(" ", 65_537)}] do
      {:noreply, rejected} = SettingsLive.handle_event("save_fleet", params, opened)
      assert rejected.assigns.fleet_form == opened.assigns.fleet_form
      assert is_binary(rejected.assigns.fleet_error)
      refute_received {:fleet_call, _, _}
    end
  end

  test "save sends only normalized desired state with server-held revision and capability", %{
    captain: captain
  } do
    opened = open(captain)

    desired =
      Map.merge(seat(), %{"desired_model" => " next-model ", "desired_effort" => " high "})

    respond(:replace, {:ok, %{"loadout" => loadout(4), "replayed" => false}})
    params = %{"seats_json" => Jason.encode!([desired])}
    {:noreply, saved} = SettingsLive.handle_event("save_fleet", params, opened)
    assert_received {:fleet_call, :replace, ["fleet-a", ^captain, request]}
    assert Enum.sort(Map.keys(request)) == ~w(idempotency_key revision seats)
    assert request["revision"] == 3
    assert request["idempotency_key"] == opened.assigns.fleet_form.idempotency_key
    assert hd(request["seats"])["desired_model"] == "next-model"
    assert hd(request["seats"])["desired_effort"] == "high"
    refute Map.has_key?(hd(request["seats"]), "scope")
    assert saved.assigns.fleet_form.revision == 4
    assert saved.assigns.fleet_form.state == :saved
    assert saved.assigns.fleet_form.submitted == request
    assert saved.assigns.fleet_error == nil

    # Queued clicks, even with different data, do not issue another replacement.
    assert {:noreply, ^saved} = SettingsLive.handle_event("save_fleet", params, saved)
    assert {:noreply, ^saved} = SettingsLive.handle_event("save_fleet", fields(), saved)
    assert {:noreply, ^saved} = SettingsLive.handle_event("retry_fleet", %{}, saved)
    assert {:noreply, ^saved} = SettingsLive.handle_event("fleet_draft", fields(), saved)
    refute_received {:fleet_call, _, _}
  end

  test "uncertain saves preserve exact normalized request and key through safe replay", %{
    captain: captain
  } do
    for failure <- [{:error, "unavailable", "Database timed out"}, :raise, :exit] do
      opened = open(captain)
      desired = Map.put(seat(), "desired_model", " intended-model ")
      params = %{"seats_json" => Jason.encode!([desired])}
      respond(:replace, failure)
      {:noreply, uncertain} = SettingsLive.handle_event("save_fleet", params, opened)
      assert_received {:fleet_call, :replace, ["fleet-a", ^captain, original]}
      assert uncertain.assigns.fleet_form.state == :uncertain
      assert uncertain.assigns.fleet_form.submitted == original
      assert uncertain.assigns.fleet_form.revision == 3
      assert uncertain.assigns.fleet_error =~ "unconfirmed"

      assert {:noreply, ^uncertain} =
               SettingsLive.handle_event("fleet_draft", fields(), uncertain)

      assert {:noreply, ^uncertain} = SettingsLive.handle_event("save_fleet", fields(), uncertain)
      refute_received {:fleet_call, _, _}

      respond(:replace, {:ok, %{"loadout" => loadout(4), "replayed" => true}})

      {:noreply, confirmed} =
        SettingsLive.handle_event(
          "retry_fleet",
          %{"revision" => 999, "seats_json" => "[]"},
          uncertain
        )

      assert_received {:fleet_call, :replace, ["fleet-a", ^captain, ^original]}
      assert confirmed.assigns.fleet_form.replayed
      assert confirmed.assigns.fleet_form.state == :saved
      assert confirmed.assigns.fleet_form.revision == 4
      assert {:noreply, ^confirmed} = SettingsLive.handle_event("retry_fleet", %{}, confirmed)
      refute_received {:fleet_call, _, _}
    end
  end

  test "conflicts retain the original draft and revision until explicit reload", %{
    captain: captain
  } do
    opened = open(captain)
    text = Jason.encode!([Map.put(seat(), "desired_model", "unsaved-model")])
    respond(:replace, {:error, "conflict", "Revision changed"})

    {:noreply, conflicted} =
      SettingsLive.handle_event("save_fleet", %{"seats_json" => text}, opened)

    assert_received {:fleet_call, :replace, _}
    assert conflicted.assigns.fleet_form.seats_json == text
    assert conflicted.assigns.fleet_form.revision == 3
    assert conflicted.assigns.fleet_form.state == :conflict
    assert conflicted.assigns.fleet_error =~ "draft is kept"
    assert {:noreply, ^conflicted} = SettingsLive.handle_event("save_fleet", fields(), conflicted)
    refute_received {:fleet_call, _, _}

    respond(:show, {:ok, %{"loadout" => loadout(5)}})

    {:noreply, reloaded} =
      SettingsLive.handle_event("reload_fleet", %{"fleet_id" => "forged-fleet"}, conflicted)

    assert_received {:fleet_call, :show, ["fleet-a", ^captain]}
    assert reloaded.assigns.fleet_form.revision == 5
    assert reloaded.assigns.fleet_form.state == :editing
    assert reloaded.assigns.fleet_form.submitted == nil

    assert reloaded.assigns.fleet_form.idempotency_key !=
             opened.assigns.fleet_form.idempotency_key

    refute reloaded.assigns.fleet_form.seats_json =~ "unsaved-model"
    assert reloaded.assigns.fleet_error == nil
  end

  test "dismiss clears state and reopening fetches a fresh named configuration", %{
    captain: captain
  } do
    opened = open(captain)

    {:noreply, drafted} =
      SettingsLive.handle_event("fleet_draft", %{"seats_json" => "bad draft"}, opened)

    {:noreply, closed} = SettingsLive.handle_event("close_fleet", %{}, drafted)
    assert closed.assigns.fleet_form == nil
    assert closed.assigns.fleet_error == nil
    assert {:noreply, ^closed} = SettingsLive.handle_event("close_fleet", %{}, closed)

    latest = Map.put(loadout(8), "id", "fleet-b")
    respond(:show, {:ok, %{"loadout" => latest}})

    {:noreply, reopened} =
      SettingsLive.handle_event("open_fleet", %{"fleet_id" => "fleet-b"}, closed)

    assert_received {:fleet_call, :show, ["fleet-b", ^captain]}
    assert reopened.assigns.fleet_form.id == "fleet-b"
    assert reopened.assigns.fleet_form.revision == 8

    assert reopened.assigns.fleet_form.idempotency_key !=
             opened.assigns.fleet_form.idempotency_key

    refute reopened.assigns.fleet_form.seats_json =~ "bad draft"
  end

  test "failed reads preserve the editor and cannot silently advance its revision", %{
    captain: captain
  } do
    opened = open(captain)
    respond(:show, {:error, "unavailable", "Cannot read fleet"})
    {:noreply, unavailable} = SettingsLive.handle_event("reload_fleet", %{}, opened)
    assert_received {:fleet_call, :show, _}
    assert unavailable.assigns.fleet_form == opened.assigns.fleet_form
    assert unavailable.assigns.fleet_error == "Cannot read fleet"
  end

  test "render is captain-only, escaped, distinguishes desired and observed, and never offers activation",
       %{
         captain: captain
       } do
    opened = open(captain)
    form = %{opened.assigns.fleet_form | seats_json: "<script>alert(1)</script>"}

    html =
      render_component(&SettingsLive.fleet_loadout_panel/1,
        capability: captain,
        form: form,
        error: nil
      )

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    assert html =~ "Expected revision 3"
    assert html =~ "Disabled"
    assert html =~ "Not activatable"
    assert html =~ "Model catalog: unverified"
    assert html =~ "Host readiness: unverified"
    assert html =~ "Desired model"
    assert html =~ "Observed model"
    assert html =~ "desired-model"
    assert html =~ "observed-model"
    assert html =~ "Canonical current scope (read-only)"
    assert html =~ "owner/repo"
    assert html =~ "Current scope revision"
    assert html =~ ~s(phx-click="close_fleet")
    assert html =~ ~s(phx-click="reload_fleet")
    assert html =~ ~s(phx-submit="save_fleet")
    assert html =~ ~s(phx-change="fleet_draft")
    refute html =~ ~s(name="revision")
    refute html =~ ~s(name="idempotency_key")
    refute html =~ ~s(name="fleet_id")
    refute html =~ ">Activate"

    locked =
      render_component(&SettingsLive.fleet_loadout_panel/1,
        capability: nil,
        form: form,
        error: nil
      )

    assert locked =~ "Unlock captain controls"
    refute locked =~ "desired-model"
    refute locked =~ "observed-model"
    refute locked =~ "fleet-loadout-editor"
  end

  test "uncertain and saved states expose explicit reconciliation without an editable submit", %{
    captain: captain
  } do
    opened = open(captain)
    form = %{opened.assigns.fleet_form | state: :uncertain}

    html =
      render_component(&SettingsLive.fleet_loadout_panel/1,
        capability: captain,
        form: form,
        error: "Unconfirmed"
      )

    assert html =~ "Retry exact submitted save"
    assert html =~ "Discard draft and reload latest"
    assert html =~ "readonly"
    refute html =~ "Save disabled configuration"

    form = %{form | state: :saved, replayed: true}

    html =
      render_component(&SettingsLive.fleet_loadout_panel/1,
        capability: captain,
        form: form,
        error: nil
      )

    assert html =~ "The original save was confirmed"
    assert html =~ "Reload to edit again"
    refute html =~ "Retry exact submitted save"
    refute html =~ "Save disabled configuration"
  end

  defp open(captain, loadout \\ loadout()) do
    respond(:show, {:ok, %{"loadout" => loadout}})

    {:noreply, opened} =
      SettingsLive.handle_event("open_fleet", %{"fleet_id" => "fleet-a"}, socket(captain))

    assert_received {:fleet_call, :show, ["fleet-a", ^captain]}
    opened
  end

  defp socket(captain) do
    {:ok, socket} = SettingsLive.mount(%{}, %{"captain" => captain}, %Phoenix.LiveView.Socket{})
    socket
  end

  defp respond(operation, response) do
    key = {Service, operation}
    Process.put(key, Process.get(key, []) ++ [response])
  end

  defp restore(key, nil), do: Application.delete_env(:agentboard, key)
  defp restore(key, value), do: Application.put_env(:agentboard, key, value)

  defp fields, do: %{"seats_json" => Jason.encode!([seat()])}

  defp seat do
    %{
      "seat_id" => "seat-a",
      "agent_id" => "agent-a",
      "harness" => "codex",
      "desired_host_id" => "host-a",
      "desired_model" => "desired-model",
      "desired_effort" => "high",
      "scope_revision" => 2
    }
  end

  defp loadout(revision \\ 3) do
    scope = %{
      "agent_id" => "agent-a",
      "state" => "managed",
      "revision" => 2,
      "allowed_repos" => ["owner/repo"],
      "required_labels" => ["Security"],
      "allowed_labels" => []
    }

    observed =
      Map.merge(seat(), %{
        "scope" => scope,
        "current_scope_revision" => 2,
        "observed_model" => "observed-model",
        "observed_retired_at" => nil
      })

    %{
      "id" => "fleet-a",
      "revision" => revision,
      "enabled" => false,
      "seat_count" => 1,
      "seats" => [observed],
      "activation_state" => "not_activatable",
      "catalog_status" => "unverified",
      "host_status" => "unverified",
      "changed_by" => "captain",
      "updated_at" => "2026-10-09T00:00:00Z"
    }
  end
end
