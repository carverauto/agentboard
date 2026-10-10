defmodule AgentboardWeb.BranchFlowSettingsLiveTest.Service do
  def show(capability), do: call(:show, [capability])
  def replace(capability, data), do: call(:replace, [capability, data])
  def reconcile(capability, data), do: call(:reconcile, [capability, data])

  defp call(operation, args) do
    send(self(), {:pin_settings_call, operation, args})
    [response | rest] = Process.get({__MODULE__, operation}, [])
    Process.put({__MODULE__, operation}, rest)

    case response do
      :raise -> raise "Simulated settings read/write failure"
      :exit -> exit(:timeout)
      response -> response
    end
  end
end

defmodule AgentboardWeb.BranchFlowSettingsLiveTest.Inventory do
  def chooser(params) do
    send(self(), {:pin_chooser_call, params})

    case Process.get({__MODULE__, :response}) do
      :raise -> raise "Simulated inventory failure"
      response -> response
    end
  end
end

defmodule AgentboardWeb.BranchFlowSettingsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AgentboardWeb.{BranchFlowSettings, SettingsLive}
  alias AgentboardWeb.BranchFlowSettingsLiveTest.{Inventory, Service}

  setup do
    previous =
      Map.new(
        ~w(captain_token branch_flow_settings_service branch_flow_inventory_service)a,
        &{&1, Application.get_env(:agentboard, &1)}
      )

    token = "fixture-branch-flow-captain-0123456789"
    Application.put_env(:agentboard, :captain_token, token)
    Application.put_env(:agentboard, :branch_flow_settings_service, Service)
    Application.put_env(:agentboard, :branch_flow_inventory_service, Inventory)
    inventory(~w(owner/alpha owner/beta owner/gamma owner/delta owner/epsilon owner/zeta))
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore(key, value) end) end)
    %{captain: Agentboard.Captain.authenticate(token)}
  end

  test "locked, forged, expired and rotated capabilities cannot use any pin event", %{
    captain: captain
  } do
    opened = open(captain)

    for capability <- [
          nil,
          %{"proof" => "forged", "expires" => System.system_time(:second) + 100},
          Map.put(captain, "expires", 0)
        ],
        event <- BranchFlowSettings.events() do
      socket = Phoenix.Component.assign(opened, capability: capability)
      rejected = event(socket, event, %{"captain" => captain, "revision" => 999})
      assert rejected.assigns.branch_flow_form == nil
      assert rejected.assigns.branch_flow_error =~ "Captain access required"
      refute_received {:pin_settings_call, _, _}
      refute_received {:pin_chooser_call, _}
    end

    Application.put_env(:agentboard, :captain_token, "rotated-branch-flow-captain-0123456789")
    rejected = event(opened, "save_branch_flow_pins")
    assert rejected.assigns.branch_flow_form == nil
    refute_received {:pin_settings_call, _, _}
  end

  test "browser actor, revision, key and replacement lists cannot change server-held state", %{
    captain: captain
  } do
    opened = open(captain)

    for field <-
          ~w(actor changed_by revision idempotency_key captain pinned_repositories branch_flow_admin),
        {name, params} <- [
          {"set_branch_flow_pin", %{"repository" => "owner/beta", "selected" => "true"}},
          {"save_branch_flow_pins", %{}},
          {"reconcile_branch_flow_pins", %{}},
          {"retry_branch_flow_pins", %{}},
          {"confirm_branch_flow_discard", %{}}
        ] do
      rejected = event(opened, name, Map.put(params, field, "forged"))
      assert rejected.assigns.branch_flow_form == opened.assigns.branch_flow_form
      assert rejected.assigns.branch_flow_error =~ "server-held"
      refute_received {:pin_settings_call, _, _}
      refute_received {:pin_chooser_call, _}
    end
  end

  test "an editor must be explicitly opened, repeated open preserves the current draft", %{
    captain: captain
  } do
    closed = socket(captain)

    for name <-
          ~w(save_branch_flow_pins close_branch_flow_pins reload_branch_flow_pins reconcile_branch_flow_pins retry_branch_flow_pins confirm_branch_flow_discard) do
      assert event(closed, name) == closed
    end

    opened = open(captain) |> select("owner/beta")
    assert event(opened, "open_branch_flow_settings") == opened
    refute_received {:pin_settings_call, _, _}
    refute_received {:pin_chooser_call, _}
  end

  test "selection is idempotent, capped at five and bounded to the shown inventory page", %{
    captain: captain
  } do
    opened = open(captain)
    draft = select(opened, "owner/beta")
    assert select(draft, "owner/beta") == draft
    assert draft.assigns.branch_flow_form.draft == ~w(owner/alpha owner/beta)
    assert draft.assigns.branch_flow_form.revision == 3

    assert draft.assigns.branch_flow_form.idempotency_key ==
             opened.assigns.branch_flow_form.idempotency_key

    rejected = select(draft, "outside/untracked")
    assert rejected.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    assert rejected.assigns.branch_flow_error =~ "current search page"
    full = draft |> select("owner/gamma") |> select("owner/delta") |> select("owner/epsilon")
    rejected = select(full, "owner/zeta")
    assert length(rejected.assigns.branch_flow_form.draft) == 5
    assert rejected.assigns.branch_flow_error =~ "at most five"

    removed =
      event(full, "set_branch_flow_pin", %{"repository" => "owner/beta", "selected" => "false"})

    assert removed.assigns.branch_flow_form.draft ==
             ~w(owner/alpha owner/gamma owner/delta owner/epsilon)

    assert event(removed, "set_branch_flow_pin", %{
             "repository" => "owner/beta",
             "selected" => "false"
           }) == removed

    refute_received {:pin_settings_call, _, _}
  end

  test "search, paging and explicit moves preserve selected order and use held cursors", %{
    captain: captain
  } do
    draft = open(captain) |> select("owner/beta") |> select("owner/gamma")

    draft =
      event(draft, "move_branch_flow_pin", %{"repository" => "owner/gamma", "direction" => "up"})

    assert draft.assigns.branch_flow_form.draft == ~w(owner/alpha owner/gamma owner/beta)
    inventory(["owner/zeta"], "held-next", "held-previous")
    searched = event(draft, "search_branch_flow_pins", %{"chooser_q" => "zeta"})
    assert searched.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    assert_received {:pin_chooser_call, %{"chooser_q" => "zeta", "chooser_cursor" => nil}}
    paged = event(searched, "page_branch_flow_pins", %{"direction" => "next"})
    assert paged.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    assert_received {:pin_chooser_call, %{"chooser_q" => "zeta", "chooser_cursor" => "held-next"}}

    rejected =
      event(paged, "page_branch_flow_pins", %{"direction" => "next", "chooser_cursor" => "forged"})

    assert rejected.assigns.branch_flow_form == paged.assigns.branch_flow_form
    assert rejected.assigns.branch_flow_error =~ "server-held"
    refute_received {:pin_chooser_call, _}
    refute_received {:pin_settings_call, _, _}
  end

  test "save uses exactly held capability, revision, request and key; queued duplicate clicks do not write",
       %{captain: captain} do
    opened = open(captain)
    draft = select(opened, "owner/beta")

    respond(
      :replace,
      {:ok, %{"settings" => config(4, draft.assigns.branch_flow_form.draft), "replayed" => false}}
    )

    saved = event(draft, "save_branch_flow_pins", %{"value" => ""})
    assert_received {:pin_settings_call, :replace, [^captain, request]}
    assert Enum.sort(Map.keys(request)) == ~w(idempotency_key pinned_repositories revision)
    assert request["revision"] == 3
    assert request["pinned_repositories"] == ~w(owner/alpha owner/beta)
    assert request["idempotency_key"] == opened.assigns.branch_flow_form.idempotency_key
    assert saved.assigns.branch_flow_form.state == :saved
    refute BranchFlowSettings.dirty?(saved.assigns.branch_flow_form)

    for name <- ~w(save_branch_flow_pins retry_branch_flow_pins reconcile_branch_flow_pins) do
      assert event(saved, name) == saved
    end

    assert select(saved, "owner/gamma") == saved
    refute_received {:pin_settings_call, _, _}
  end

  test "unchanged configuration does not write, and empty pin replacement is explicit", %{
    captain: captain
  } do
    opened = open(captain)
    assert event(opened, "save_branch_flow_pins") == opened
    refute_received {:pin_settings_call, _, _}
    draft = event(opened, "remove_branch_flow_pin", %{"repository" => "owner/alpha"})
    respond(:replace, {:ok, %{"settings" => config(4, []), "replayed" => false}})
    saved = event(draft, "save_branch_flow_pins")
    assert_received {:pin_settings_call, :replace, [^captain, %{"pinned_repositories" => []}]}
    assert saved.assigns.branch_flow_form.draft == []
  end

  test "uncertain save cannot retry or change its exact request before read-only reconciliation",
       %{captain: captain} do
    uncertain = uncertain(captain)
    form = uncertain.assigns.branch_flow_form
    assert form.state == :uncertain
    assert event(uncertain, "retry_branch_flow_pins") == uncertain
    assert event(uncertain, "save_branch_flow_pins") == uncertain
    assert select(uncertain, "owner/gamma") == uncertain
    refute_received {:pin_settings_call, _, _}
    respond(:reconcile, :exit)
    still_uncertain = event(uncertain, "reconcile_branch_flow_pins")
    assert_received {:pin_settings_call, :reconcile, [^captain, request]}
    assert request == form.submitted
    assert still_uncertain.assigns.branch_flow_form == form
    assert still_uncertain.assigns.branch_flow_error =~ "unavailable reads"
    respond(:reconcile, {:error, "unavailable", "Database down"})
    unchanged = event(still_uncertain, "reload_branch_flow_pins")
    assert unchanged.assigns.branch_flow_form == form
    assert_received {:pin_settings_call, :reconcile, [^captain, ^request]}
    refute_received {:pin_settings_call, :show, _}
    refute_received {:pin_settings_call, :replace, _}
  end

  test "retry_safe reconciliation permits only an explicit exact-request same-key retry", %{
    captain: captain
  } do
    uncertain = uncertain(captain)
    original = uncertain.assigns.branch_flow_form.submitted
    respond(:reconcile, reconciled("retry_safe", config()))
    ready = event(uncertain, "reconcile_branch_flow_pins")
    assert_received {:pin_settings_call, :reconcile, [^captain, ^original]}
    assert ready.assigns.branch_flow_form.state == :retry_ready
    refute_received {:pin_settings_call, :replace, _}

    respond(
      :replace,
      {:ok, %{"settings" => config(4, original["pinned_repositories"]), "replayed" => false}}
    )

    saved = event(ready, "retry_branch_flow_pins")
    assert_received {:pin_settings_call, :replace, [^captain, ^original]}
    assert saved.assigns.branch_flow_form.state == :saved
    assert event(saved, "retry_branch_flow_pins") == saved
    refute_received {:pin_settings_call, _, _}
  end

  test "abandoning a retry-safe request needs confirmed reload and fresh read-only reconciliation",
       %{captain: captain} do
    uncertain = uncertain(captain)
    original = uncertain.assigns.branch_flow_form
    respond(:reconcile, reconciled("retry_safe", config()))
    ready = event(uncertain, "reconcile_branch_flow_pins")
    assert_received {:pin_settings_call, :reconcile, [^captain, _]}
    asking = event(ready, "reload_branch_flow_pins")
    assert asking.assigns.branch_flow_form.confirmation == :reload
    assert event(asking, "retry_branch_flow_pins") == asking
    refute_received {:pin_settings_call, _, _}
    respond(:reconcile, reconciled("retry_safe", config()))
    respond(:show, shown(config()))
    reloaded = event(asking, "confirm_branch_flow_discard")
    assert_received {:pin_settings_call, :reconcile, [^captain, request]}
    assert request == original.submitted
    assert_received {:pin_settings_call, :show, [^captain]}
    assert_received {:pin_chooser_call, %{}}
    assert reloaded.assigns.branch_flow_form.state == :editing
    assert reloaded.assigns.branch_flow_form.draft == ["owner/alpha"]
    refute reloaded.assigns.branch_flow_form.idempotency_key == original.idempotency_key
    refute_received {:pin_settings_call, :replace, _}
  end

  test "unavailable or changed reconciliation blocks abandoning a previously retry-safe request",
       %{captain: captain} do
    uncertain = uncertain(captain)
    original = uncertain.assigns.branch_flow_form
    respond(:reconcile, reconciled("retry_safe", config()))
    ready = event(uncertain, "reconcile_branch_flow_pins")
    assert_received {:pin_settings_call, :reconcile, [^captain, _]}

    for {response, expected_state} <- [
          {:exit, :uncertain},
          {reconciled("conflict", config(8)), :conflict},
          {reconciled("committed", config(8, ["owner/gamma"]), config(4, original.draft)), :saved}
        ] do
      asking = event(ready, "reload_branch_flow_pins")
      respond(:reconcile, response)
      result = event(asking, "confirm_branch_flow_discard")
      assert_received {:pin_settings_call, :reconcile, [^captain, request]}
      assert request == original.submitted
      assert result.assigns.branch_flow_form.state == expected_state
      assert result.assigns.branch_flow_form.idempotency_key == original.idempotency_key

      if expected_state == :saved do
        assert result.assigns.branch_flow_form.committed["revision"] == 4
        assert result.assigns.branch_flow_form.config["revision"] == 8
      else
        assert result.assigns.branch_flow_form.draft == original.draft
      end

      refute_received {:pin_settings_call, :show, _}
      refute_received {:pin_settings_call, :replace, _}
    end
  end

  test "an old committed receipt is distinct from newer current settings", %{captain: captain} do
    uncertain = uncertain(captain)
    committed = config(4, ~w(owner/alpha owner/beta))
    current = config(7, ["owner/gamma"])
    respond(:reconcile, reconciled("committed", current, committed))
    saved = event(uncertain, "reconcile_branch_flow_pins")
    assert_received {:pin_settings_call, :reconcile, [^captain, _]}
    assert saved.assigns.branch_flow_form.committed["revision"] == 4
    assert saved.assigns.branch_flow_form.config["revision"] == 7
    assert saved.assigns.branch_flow_form.draft == ["owner/gamma"]
    html = render(saved)
    assert html =~ "Your save was committed at revision 4"
    assert html =~ "later configuration is now saved at revision 7"
    refute html =~ ~s(id="branch-flow-retry")
    refute_received {:pin_settings_call, :replace, _}
  end

  test "a replay response is reconciled before claiming latest configuration", %{captain: captain} do
    draft = open(captain) |> select("owner/beta")
    committed = config(4, draft.assigns.branch_flow_form.draft)
    respond(:replace, {:ok, %{"settings" => committed, "replayed" => true}})
    respond(:reconcile, reconciled("committed", config(9, ["owner/gamma"]), committed))
    saved = event(draft, "save_branch_flow_pins")
    assert_received {:pin_settings_call, :replace, [^captain, request]}
    assert_received {:pin_settings_call, :reconcile, [^captain, ^request]}
    assert saved.assigns.branch_flow_form.config["revision"] == 9
    assert saved.assigns.branch_flow_form.committed["revision"] == 4
    assert saved.assigns.branch_flow_form.draft == ["owner/gamma"]
  end

  test "replay with unavailable current read remains uncertain with original request and draft",
       %{captain: captain} do
    draft = open(captain) |> select("owner/beta")
    respond(:replace, {:ok, %{"settings" => config(4), "replayed" => true}})
    respond(:reconcile, :raise)
    uncertain = event(draft, "save_branch_flow_pins")
    assert_received {:pin_settings_call, :replace, [^captain, request]}
    assert_received {:pin_settings_call, :reconcile, [^captain, ^request]}
    assert uncertain.assigns.branch_flow_form.state == :uncertain
    assert uncertain.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    assert uncertain.assigns.branch_flow_form.config["revision"] == 3
  end

  test "stale conflicts preserve draft and require explicit confirmed reload", %{captain: captain} do
    draft = open(captain) |> select("owner/beta")
    respond(:replace, {:error, "conflict", "Expected revision is stale"})
    conflict = event(draft, "save_branch_flow_pins")
    assert_received {:pin_settings_call, :replace, [^captain, _]}
    assert conflict.assigns.branch_flow_form.state == :conflict
    assert conflict.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    assert conflict.assigns.branch_flow_error =~ "Your draft is kept"
    asking = event(conflict, "reload_branch_flow_pins")
    assert asking.assigns.branch_flow_form.confirmation == :reload
    refute_received {:pin_settings_call, :show, _}
    kept = event(asking, "cancel_branch_flow_discard")
    assert kept.assigns.branch_flow_form == conflict.assigns.branch_flow_form
    respond(:show, shown(config(8, ["owner/gamma"])))
    reloaded = kept |> event("reload_branch_flow_pins") |> event("confirm_branch_flow_discard")
    assert_received {:pin_settings_call, :show, [^captain]}
    assert_received {:pin_chooser_call, %{}}
    assert reloaded.assigns.branch_flow_form.draft == ["owner/gamma"]
    assert reloaded.assigns.branch_flow_form.revision == 8

    refute reloaded.assigns.branch_flow_form.idempotency_key ==
             draft.assigns.branch_flow_form.idempotency_key
  end

  test "absent receipt with newer current revision reconciles to conflict without retry", %{
    captain: captain
  } do
    uncertain = uncertain(captain)
    respond(:reconcile, reconciled("conflict", config(6, ["owner/gamma"])))
    conflict = event(uncertain, "reconcile_branch_flow_pins")
    assert_received {:pin_settings_call, :reconcile, [^captain, _]}
    assert conflict.assigns.branch_flow_form.state == :conflict
    assert conflict.assigns.branch_flow_form.draft == uncertain.assigns.branch_flow_form.draft

    assert conflict.assigns.branch_flow_form.idempotency_key ==
             uncertain.assigns.branch_flow_form.idempotency_key

    assert event(conflict, "retry_branch_flow_pins") == conflict
    refute_received {:pin_settings_call, :replace, _}
  end

  test "dirty close requires confirmation and delayed events cannot reopen dismissed editor", %{
    captain: captain
  } do
    draft = open(captain) |> select("owner/beta")
    assert event(draft, "confirm_branch_flow_discard") == draft
    asking = event(draft, "close_branch_flow_pins")
    assert asking.assigns.branch_flow_form.confirmation == :close
    assert asking.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    assert render(asking) =~ ~s(id="branch-flow-discard-confirmation")
    kept = event(asking, "cancel_branch_flow_discard")
    assert kept.assigns.branch_flow_form == draft.assigns.branch_flow_form
    closed = kept |> event("close_branch_flow_pins") |> event("confirm_branch_flow_discard")
    assert closed.assigns.branch_flow_form == nil

    for name <-
          ~w(save_branch_flow_pins reload_branch_flow_pins retry_branch_flow_pins reconcile_branch_flow_pins confirm_branch_flow_discard) do
      assert event(closed, name) == closed
    end

    assert select(closed, "owner/gamma") == closed
    refute_received {:pin_settings_call, _, _}
  end

  test "closing an uncertain editor retains the request; reopen reconciles without a new key", %{
    captain: captain
  } do
    uncertain = uncertain(captain)
    original = uncertain.assigns.branch_flow_form
    closed = uncertain |> event("close_branch_flow_pins") |> event("confirm_branch_flow_discard")
    assert closed.assigns.branch_flow_form == nil
    assert closed.assigns.branch_flow_pending.submitted == original.submitted
    refute_received {:pin_settings_call, _, _}
    respond(:reconcile, :exit)
    reopened = event(closed, "open_branch_flow_settings")
    assert_received {:pin_settings_call, :reconcile, [^captain, request]}
    assert request == original.submitted
    assert reopened.assigns.branch_flow_form.state == :uncertain
    assert reopened.assigns.branch_flow_form.idempotency_key == original.idempotency_key
    assert reopened.assigns.branch_flow_form.draft == original.draft
    refute_received {:pin_settings_call, :show, _}
    refute_received {:pin_settings_call, :replace, _}

    closed_again =
      reopened |> event("close_branch_flow_pins") |> event("confirm_branch_flow_discard")

    respond(
      :reconcile,
      reconciled("committed", config(8, ["owner/gamma"]), config(4, original.draft))
    )

    confirmed = event(closed_again, "open_branch_flow_settings")
    assert_received {:pin_settings_call, :reconcile, [^captain, ^request]}
    assert confirmed.assigns.branch_flow_form.state == :saved
    assert confirmed.assigns.branch_flow_form.config["revision"] == 8
    assert confirmed.assigns.branch_flow_form.committed["revision"] == 4
    assert confirmed.assigns.branch_flow_form.idempotency_key == original.idempotency_key
  end

  test "failed initial load is degraded rather than empty; failed reload never discards the draft",
       %{captain: captain} do
    respond(:show, :raise)
    failed = event(socket(captain), "open_branch_flow_settings")
    assert_received {:pin_settings_call, :show, [^captain]}
    assert failed.assigns.branch_flow_form == nil
    assert failed.assigns.branch_flow_error =~ "not an empty pin list"
    refute render(failed) =~ "No pins selected"
    draft = open(captain) |> select("owner/beta")
    asking = event(draft, "reload_branch_flow_pins")
    respond(:show, :exit)
    unchanged = event(asking, "confirm_branch_flow_discard")
    assert_received {:pin_settings_call, :show, [^captain]}
    assert unchanged.assigns.branch_flow_form == asking.assigns.branch_flow_form
    assert unchanged.assigns.branch_flow_error =~ "unchanged"
  end

  test "failed search keeps selections, prevents unverified additions and never implies empty inventory",
       %{captain: captain} do
    draft = open(captain) |> select("owner/beta")
    Process.put({Inventory, :response}, :raise)
    failed = event(draft, "search_branch_flow_pins", %{"chooser_q" => "anything"})
    assert_received {:pin_chooser_call, _}
    assert failed.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    assert failed.assigns.branch_flow_form.chooser.total == nil
    html = render(failed)
    assert html =~ "Repository inventory unavailable"
    refute html =~ "No tracked repositories match"
    rejected = select(failed, "owner/gamma")
    assert rejected.assigns.branch_flow_error =~ "inventory is unavailable"
    refute_received {:pin_settings_call, _, _}
  end

  test "unavailable saved pins stay visible unchanged until explicitly removed", %{
    captain: captain
  } do
    old = config(3, ~w(gone/repository owner/alpha))
    opened = open(captain, old, %{"gone/repository" => false, "owner/alpha" => true})
    assert opened.assigns.branch_flow_form.draft == old["pinned_repositories"]
    assert render(opened) =~ "Unavailable saved pin"
    draft = select(opened, "owner/beta")
    rejected = event(draft, "save_branch_flow_pins")
    assert rejected.assigns.branch_flow_error =~ "Remove unavailable pins explicitly"
    assert rejected.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    refute_received {:pin_settings_call, :replace, _}
    repaired = event(rejected, "remove_branch_flow_pin", %{"repository" => "gone/repository"})

    respond(
      :replace,
      {:ok, %{"settings" => config(4, ~w(owner/alpha owner/beta)), "replayed" => false}}
    )

    saved = event(repaired, "save_branch_flow_pins")

    assert_received {:pin_settings_call, :replace,
                     [^captain, %{"pinned_repositories" => ["owner/alpha", "owner/beta"]}]}

    assert saved.assigns.branch_flow_form.state == :saved
  end

  test "backend rejection preserves desired pins; lost authority closes without inventing a write",
       %{captain: captain} do
    draft = open(captain) |> select("owner/beta")
    respond(:replace, {:error, "invalid_input", "Pinned repository became unavailable"})
    invalid = event(draft, "save_branch_flow_pins")
    assert_received {:pin_settings_call, :replace, [^captain, _]}
    assert invalid.assigns.branch_flow_form.draft == draft.assigns.branch_flow_form.draft
    assert invalid.assigns.branch_flow_form.state == :editing
    respond(:replace, {:error, "forbidden", "Expired at write boundary"})
    rejected = event(invalid, "save_branch_flow_pins")
    assert_received {:pin_settings_call, :replace, [^captain, _]}
    assert rejected.assigns.branch_flow_form == nil
    assert rejected.assigns.branch_flow_error =~ "Captain access required"
  end

  test "panel provides accessible explicit controls and never renders capability or save key", %{
    captain: captain
  } do
    draft = open(captain) |> select("owner/beta")
    html = render(draft)
    assert html =~ "PR branch flow"
    assert html =~ "Pins change display only"
    assert html =~ "Integration roles and intake changes are not available"
    assert html =~ ~s(phx-hook="BranchFlowPinEditor")
    assert html =~ ~s(data-dirty="true")
    assert html =~ ~s(data-selected-pin="owner/alpha")
    assert html =~ ~s(aria-label="Move owner/beta up")
    assert html =~ ~s(aria-label="Remove owner/beta pin")
    assert html =~ "up to 20 per page"
    assert html =~ "nothing auto-saves"
    refute html =~ draft.assigns.branch_flow_form.idempotency_key
    refute html =~ captain["proof"]
    locked = render(socket(nil))
    assert locked =~ "Unlock captain controls"
    refute locked =~ ~s(id="branch-flow-open")
    refute locked =~ ~s(id="branch-flow-save")
  end

  defp event(socket, event, params \\ %{}) do
    {:noreply, socket} = SettingsLive.handle_event(event, params, socket)
    socket
  end

  defp select(socket, repo),
    do:
      event(socket, "set_branch_flow_pin", %{
        "repository" => repo,
        "selected" => "true",
        "value" => ""
      })

  defp uncertain(captain) do
    draft = open(captain) |> select("owner/beta")
    respond(:replace, :exit)
    uncertain = event(draft, "save_branch_flow_pins")
    assert_received {:pin_settings_call, :replace, [^captain, _]}
    uncertain
  end

  defp open(captain, config \\ config(), availability \\ nil) do
    respond(:show, shown(config, availability))
    opened = event(socket(captain), "open_branch_flow_settings", %{"value" => ""})
    assert_received {:pin_settings_call, :show, [^captain]}
    assert_received {:pin_chooser_call, %{}}
    opened
  end

  defp socket(captain) do
    {:ok, socket} = SettingsLive.mount(%{}, %{"captain" => captain}, %Phoenix.LiveView.Socket{})
    socket
  end

  defp render(socket),
    do:
      render_component(&BranchFlowSettings.panel/1,
        capability: socket.assigns.capability,
        form: socket.assigns.branch_flow_form,
        error: socket.assigns.branch_flow_error
      )

  defp config(revision \\ 3, pins \\ ["owner/alpha"]),
    do: %{
      "revision" => revision,
      "pinned_repositories" => pins,
      "changed_by" => "captain",
      "updated_at" => "2026-10-09T20:00:00Z"
    }

  defp shown(config, availability \\ nil),
    do:
      {:ok,
       %{
         "settings" => config,
         "availability" => availability || Map.new(config["pinned_repositories"], &{&1, true})
       }}

  defp reconciled(status, current, committed \\ nil),
    do:
      {:ok,
       %{
         "status" => status,
         "settings" => current,
         "committed_settings" => committed,
         "availability" => Map.new(current["pinned_repositories"], &{&1, true}),
         "replayed" => status == "committed"
       }}

  defp inventory(repositories, next \\ nil, previous \\ nil) do
    rows =
      Enum.map(
        repositories,
        &%{
          repository: &1,
          open_count: 1,
          unknown_lifecycle_count: 0,
          terminal_count: 0,
          red_count: 0
        }
      )

    Process.put({Inventory, :response}, %{
      repositories: rows,
      total: length(rows),
      next_cursor: next,
      previous_cursor: previous,
      error: nil
    })
  end

  defp respond(operation, response) do
    key = {Service, operation}
    Process.put(key, Process.get(key, []) ++ [response])
  end

  defp restore(key, nil), do: Application.delete_env(:agentboard, key)
  defp restore(key, value), do: Application.put_env(:agentboard, key, value)
end
