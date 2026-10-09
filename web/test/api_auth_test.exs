defmodule Agentboard.APIAuthTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Agentboard.Auth.APIAuthPolicy, as: Policy
  alias AgentboardWeb.Plugs.AgentAuth
  alias AgentboardWeb.{APIController, ConversationController, DecisionController, WatchController}

  setup do
    keys = [:agent_auth_mode, :captain_token, :coordinator_id]
    prior = Map.new(keys, &{&1, Application.fetch_env(:agentboard, &1)})
    Application.put_env(:agentboard, :agent_auth_mode, "enforce")
    Application.put_env(:agentboard, :captain_token, "fixture-captain-capability-0123456789")
    Application.put_env(:agentboard, :coordinator_id, "coordinator")

    on_exit(fn ->
      Enum.each(prior, fn
        {key, {:ok, value}} -> Application.put_env(:agentboard, key, value)
        {key, :error} -> Application.delete_env(:agentboard, key)
      end)
    end)

    :ok
  end

  defp route(controller, action), do: %{plug: controller, plug_opts: action}
  defp observer, do: %{scope: "coordinator", agent_id: "coordinator"}

  test "read-only scope is an explicit operation allowlist, never all GET" do
    for {controller, action} <- [
          {APIController, :tasks},
          {APIController, :task},
          {APIController, :prs},
          {APIController, :pr},
          {APIController, :agents},
          {APIController, :agent},
          {DecisionController, :index},
          {DecisionController, :show},
          {DecisionController, :waiting},
          {DecisionController, :wakes},
          {WatchController, :tasks}
        ] do
      assert Policy.allowed?(observer(), route(controller, action), "GET", %{})
      refute Policy.allowed?(observer(), route(controller, action), "POST", %{})
    end

    for {controller, action} <- [
          {ConversationController, :reads},
          {ConversationController, :coverage},
          {ConversationController, :diagnostics},
          {APIController, :context_feed},
          {APIController, :documents},
          {APIController, :quota},
          {WatchController, :quota},
          {AgentboardWeb.WorkerController, :operate},
          {APIController, :future_read}
        ] do
      refute Policy.allowed?(observer(), route(controller, action), "GET", %{})
    end
  end

  test "coordinator inbox cannot be widened by destination or task filters" do
    for controller <- [APIController, WatchController] do
      info = route(controller, :messages)
      assert Policy.allowed?(observer(), info, "GET", %{})
      assert Policy.allowed?(observer(), info, "GET", %{"to" => "coordinator"})
      refute Policy.allowed?(observer(), info, "GET", %{"to" => "another-agent"})
      refute Policy.allowed?(observer(), info, "GET", %{"task" => "any-task"})

      refute Policy.allowed?(observer(), info, "GET", %{
               "to" => "coordinator",
               "task" => "any-task"
             })

      refute Policy.allowed?(observer(), info, "POST", %{})
    end
  end

  test "verification rechecks current identity, lifecycle, reserved status and coordinator binding" do
    agent = %{id: "seat", harness: "codex", kind: "seat", retired_at: nil}
    credential = %{agent_id: "seat", scope: "agent", revoked_at: nil}
    assert Policy.credential_allowed?(credential, agent, "coordinator")
    refute Policy.credential_allowed?(credential, nil, "coordinator")
    refute Policy.credential_allowed?(%{credential | revoked_at: DateTime.utc_now()}, agent, nil)
    refute Policy.credential_allowed?(credential, %{agent | retired_at: DateTime.utc_now()}, nil)
    refute Policy.credential_allowed?(credential, %{agent | harness: "ash"}, nil)
    refute Policy.credential_allowed?(credential, %{agent | kind: "system"}, nil)
    refute Policy.credential_allowed?(credential, %{agent | id: "another-seat"}, nil)
    refute Policy.credential_allowed?(credential, agent, "seat")

    for scope <- ["captain-admin", "system", "unknown"] do
      refute Policy.credential_allowed?(%{credential | scope: scope}, agent, nil)
    end

    coordinator = %{credential | scope: "coordinator"}
    assert Policy.credential_allowed?(coordinator, agent, "seat")
    refute Policy.credential_allowed?(coordinator, agent, "new-coordinator")
    refute Policy.credential_allowed?(coordinator, agent, nil)

    for {id, harness, kind} <- [
          {"captain", "codex", "seat"},
          {"system-any", "codex", "seat"},
          {"worker", "server", "seat"},
          {"decision-maintenance", "codex", "seat"}
        ] do
      assert Policy.reserved?(id, harness, kind)
    end
  end

  test "enforce rejects anonymous requests and never falls back to actor headers" do
    for path <- [
          "/api/v1/tasks",
          "/api/v1/conversations/reads",
          "/api/v1/conversations/diagnostics"
        ] do
      conn =
        Plug.Test.conn(:get, path)
        |> put_req_header("x-agentboard-agent", "coordinator")
        |> put_req_header("x-agentboard-model", "spoof")
        |> put_req_header("x-agentboard-harness", "codex")

      assert AgentAuth.actor(conn) == %{}
      out = AgentAuth.call(conn, [])
      assert out.halted and out.status == 401
    end

    trusted = %{"agent" => "verified", "model" => "fixture", "harness" => "codex"}

    conn =
      Plug.Test.conn(:get, "/api/v1/tasks")
      |> assign(:trusted_actor, trusted)
      |> put_req_header("x-agentboard-agent", "forged")

    assert AgentAuth.actor(conn) == trusted
  end

  test "duplicate and malformed authorization is rejected before token verification" do
    for values <- [
          ["Bearer one", "Bearer two"],
          ["Basic opaque"],
          ["Bearer "],
          ["Bearer one, Bearer two"],
          ["Bearer one two"],
          ["Bearer one\ttwo"]
        ] do
      conn = Plug.Test.conn(:get, "/api/v1/tasks")
      conn = %{conn | req_headers: Enum.map(values, &{"authorization", &1})}
      assert {:error, "unauthorized", _} = AgentAuth.bearer(conn)
      out = AgentAuth.call(conn, [])
      assert out.halted and out.status == 401
    end

    assert {:ok, nil} = Agentboard.Auth.verify("abt_" <> String.duplicate("!", 43))
    assert {:ok, nil} = Agentboard.Auth.verify("abt_short")
  end

  test "privileged report and settings reads require independent captain capability" do
    for path <- [
          "/api/v1/auth/observations",
          "/api/v1/settings/archive",
          "/api/v1/agents/seat/tokens"
        ] do
      denied = Plug.Test.conn(:get, path) |> AgentAuth.call([])
      assert denied.halted and denied.status == 403

      allowed =
        Plug.Test.conn(:get, path)
        |> put_req_header("authorization", "Bearer fixture-captain-capability-0123456789")
        |> AgentAuth.call([])

      refute allowed.halted
      assert get_resp_header(allowed, "cache-control") == ["no-store"]
    end
  end

  test "seat scope permits coordinator inspection but keeps captain-only writes" do
    assert Policy.captain_operation?(route(APIController, :seat_scope), %{})
    assert Policy.captain_operation?(route(APIController, :set_seat_scope), %{})
    refute Policy.allowed?(observer(), route(APIController, :set_seat_scope), "PUT", %{})
    assert Policy.allowed?(observer(), route(APIController, :seat_scope), "GET", %{})
    assert Policy.allowed?(observer(), route(APIController, :agent), "GET", %{})
    assert Policy.boundary(route(APIController, :set_seat_scope)) == :agent
  end

  test "captain does not become an ordinary agent or a worker principal" do
    denied =
      Plug.Test.conn(:post, "/api/v1/tasks")
      |> put_req_header("authorization", "Bearer fixture-captain-capability-0123456789")
      |> AgentAuth.call([])

    assert denied.halted and denied.status == 403
    refute Policy.captain_operation?(route(ConversationController, :send), %{})
    assert Policy.captain_operation?(route(APIController, :mutate), %{"action" => "assign"})
    refute Policy.captain_operation?(route(APIController, :mutate), %{"action" => "claim"})
    assert Policy.boundary(route(AgentboardWeb.WorkerController, :operate)) == :independent
    assert Policy.boundary(route(AgentboardWeb.WorkflowHookController, :create)) == :independent
    assert Policy.boundary(route(AgentboardWeb.WorkerController, :future_operation)) == :deny
  end

  test "captain bootstrap binds target headers only on registration" do
    conn =
      Plug.Test.conn(:post, "/api/v1/agents/register")
      |> put_req_header("authorization", "Bearer fixture-captain-capability-0123456789")
      |> put_req_header("x-agentboard-agent", "new-seat")
      |> put_req_header("x-agentboard-model", "fixture")
      |> put_req_header("x-agentboard-harness", "codex")

    conn = %{conn | body_params: %{}}
    out = AgentAuth.call(conn, [])
    refute out.halted
    assert out.assigns.api_auth_kind == :captain_bootstrap
    assert out.assigns.trusted_actor["agent"] == "new-seat"
    denied = conn |> put_req_header("x-agentboard-agent", "system-spoof") |> AgentAuth.call([])
    assert denied.halted and denied.status == 403

    duplicate =
      %{conn | req_headers: [{"x-agentboard-agent", "another"} | conn.req_headers]}
      |> AgentAuth.call([])

    assert duplicate.halted and duplicate.status == 401
  end

  test "off and observe retain legacy attribution; invalid mode fails closed" do
    conn = Plug.Test.conn(:get, "/api/v1/tasks") |> put_req_header("x-agentboard-agent", "legacy")

    for mode <- ["off", "observe"] do
      Application.put_env(:agentboard, :agent_auth_mode, mode)
      refute AgentAuth.call(conn, []).halted
      assert AgentAuth.actor(conn)["agent"] == "legacy"
    end

    Application.put_env(:agentboard, :agent_auth_mode, "enfroce")
    out = AgentAuth.call(conn, [])
    assert out.halted and out.status == 503
  end
end
