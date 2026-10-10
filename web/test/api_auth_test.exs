defmodule Agentboard.APIAuthTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Agentboard.Auth.APIAuthPolicy, as: Policy
  alias AgentboardWeb.Plugs.AgentAuth
  alias AgentboardWeb.{APIController, ConversationController, DecisionController, WatchController}

  setup do
    keys = [:agent_auth_mode, :captain_token, :coordinator_id, :mattermost_channel_allowlist]
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

  defp participant,
    do: %{scope: "coordinator_participant", agent_id: "coordinator", channel_ids: ["channel-1"]}

  test "participant scope is explicit and requires a bounded distinct channel grant" do
    for channels <- [
          nil,
          [],
          "channel-1",
          [nil],
          [""],
          ["with space"],
          ["a/b"],
          ["a\n"],
          ["é"],
          [String.duplicate("a", 129)],
          ["channel-1", "channel-1"],
          Enum.map(1..21, &"channel-#{&1}")
        ] do
      refute Policy.valid_channel_grant?("coordinator_participant", channels)
    end

    assert Policy.valid_channel_grant?("coordinator_participant", [String.duplicate("a", 128)])

    assert Policy.valid_channel_grant?(
             "coordinator_participant",
             Enum.map(1..20, &"channel-#{&1}")
           )

    for scope <- ~w(agent coordinator) do
      assert Policy.valid_channel_grant?(scope, [])
      refute Policy.valid_channel_grant?(scope, ["channel-1"])
    end

    refute Policy.valid_channel_grant?("unknown", [])

    agent = %{id: "coordinator", harness: "codex", kind: "seat", retired_at: nil}
    credential = participant() |> Map.put(:revoked_at, nil)
    assert Policy.credential_allowed?(credential, agent, "coordinator")
    refute Policy.credential_allowed?(%{credential | channel_ids: []}, agent, "coordinator")
    refute Policy.credential_allowed?(credential, agent, "replacement")

    refute Policy.credential_allowed?(
             %{credential | revoked_at: DateTime.utc_now()},
             agent,
             "coordinator"
           )

    refute Policy.credential_allowed?(
             credential,
             %{agent | retired_at: DateTime.utc_now()},
             "coordinator"
           )
  end

  test "participant allowlist permits only named method operations and own inbox filters" do
    for {controller, action, method} <- [
          {APIController, :heartbeat, "POST"},
          {APIController, :read_message, "POST"},
          {ConversationController, :send, "POST"},
          {ConversationController, :report_coverage, "POST"},
          {ConversationController, :reads, "GET"},
          {ConversationController, :coverage, "GET"},
          {ConversationController, :diagnostics, "GET"},
          {APIController, :tasks, "GET"},
          {APIController, :message, "GET"},
          {APIController, :message_triage, "GET"},
          {DecisionController, :show, "GET"},
          {WatchController, :tasks, "GET"}
        ] do
      assert Policy.allowed?(participant(), route(controller, action), method, %{})
      refute Policy.allowed?(participant(), route(controller, action), "DELETE", %{})
    end

    for {controller, action} <- [
          {APIController, :register},
          {APIController, :create},
          {APIController, :edit},
          {APIController, :mutate},
          {APIController, :set_availability},
          {APIController, :set_seat_scope},
          {APIController, :push_quota},
          {APIController, :context_publish},
          {APIController, :send_message},
          {APIController, :future_write},
          {DecisionController, :create},
          {DecisionController, :mutate},
          {DecisionController, :promote},
          {DecisionController, :wake_mutate},
          {AgentboardWeb.AgentTokenController, :mutate},
          {AgentboardWeb.WorkerController, :operate}
        ],
        method <- ["GET", "POST", "PUT", "PATCH"] do
      refute Policy.allowed?(participant(), route(controller, action), method, %{})
    end

    for controller <- [APIController, WatchController] do
      assert Policy.allowed?(participant(), route(controller, :messages), "GET", %{})

      refute Policy.allowed?(participant(), route(controller, :messages), "GET", %{
               "to" => "other"
             })

      refute Policy.allowed?(participant(), route(controller, :messages), "GET", %{
               "task" => "any"
             })
    end

    refute Policy.allowed?(
             %{participant() | channel_ids: []},
             route(APIController, :tasks),
             "GET",
             %{}
           )
  end

  test "typed conversation boundary splits requester and participant operations" do
    controller = AgentboardWeb.DecisionConversationController
    assert Policy.boundary(route(controller, :notify)) == :agent

    for {scope, action, method, permitted} <- [
          {"agent", :notify, "POST", true},
          {"agent", :reply, "POST", false},
          {"agent", :show, "GET", true},
          {"agent", :reconcile, "POST", true},
          {"agent", :notify, "GET", false},
          {"agent", :future_operation, "POST", false},
          {"coordinator_participant", :notify, "POST", false},
          {"coordinator_participant", :reply, "POST", true},
          {"coordinator_participant", :show, "GET", true},
          {"coordinator_participant", :reconcile, "POST", true},
          {"coordinator_participant", :reply, "GET", false}
        ] do
      principal = %{participant() | scope: scope}
      assert Policy.allowed?(principal, route(controller, action), method, %{}) == permitted
      refute Policy.allowed?(observer(), route(controller, action), method, %{})
    end
  end

  test "credential metadata exposes immutable grant without hash or token" do
    row =
      Map.merge(participant(), %{
        id: "fixture",
        token_hash: "hash-secret",
        token: "token-secret",
        created_at: nil
      })

    metadata = Agentboard.Auth.metadata(row)
    assert metadata.channel_ids == ["channel-1"]
    refute Map.has_key?(metadata, :token_hash)
    refute Map.has_key?(metadata, :token)
  end

  test "participant path identity and channel denials happen before operations" do
    principal = participant()
    actor = %{"agent" => principal.agent_id, "model" => "fixture", "harness" => "codex"}

    conn =
      Plug.Test.conn(:post, "/api/v1/agents/other/heartbeat", %{"status" => "idle"})
      |> assign(:authenticated_agent, principal)
      |> assign(:trusted_actor, actor)

    assert APIController.heartbeat(conn, %{"id" => "other"}).status == 403

    conn =
      Plug.Test.conn(:get, "/api/v1/conversations/coverage/other/channel-1")
      |> assign(:authenticated_agent, principal)
      |> assign(:trusted_actor, actor)

    assert ConversationController.coverage(conn, %{
             "agent_id" => "other",
             "channel_id" => "channel-1"
           }).status == 403

    assert ConversationController.reads(conn, %{"channel_id" => "foreign"}).status == 403

    assert ConversationController.send(conn, %{"channel_id" => "foreign", "body" => "denied"}).status ==
             403

    conn =
      Plug.Test.conn(:get, "/api/v1/messages?to=other")
      |> fetch_query_params()
      |> assign(:authenticated_agent, principal)
      |> assign(:trusted_actor, actor)

    assert {:error, "forbidden", _} = APIController.message_filters(conn, "messages")
  end

  test "local receipt authorization checks grants and current global policy without remote work" do
    alias Agentboard.Mattermost.Participation
    Application.put_env(:agentboard, :mattermost_channel_allowlist, "channel-1, channel-2")
    assert :ok = Participation.authorize_local(participant(), "channel-1")
    assert {:error, "forbidden", _} = Participation.authorize_local(participant(), "channel-2")
    assert {:error, "forbidden", _} = Participation.authorize_local(observer(), "channel-1")

    assert {:error, "forbidden", _} =
             Participation.authorize_local(%{participant() | channel_ids: []}, "channel-1")

    Application.put_env(:agentboard, :mattermost_channel_allowlist, "channel-2")
    assert {:error, "forbidden", _} = Participation.authorize_local(participant(), "channel-1")
    Application.put_env(:agentboard, :mattermost_channel_allowlist, "")
    assert :ok = Participation.authorize_local(participant(), "channel-1")
    Application.put_env(:agentboard, :mattermost_channel_allowlist, [nil])
    assert {:error, "forbidden", _} = Participation.authorize_local(participant(), "channel-1")
    Application.put_env(:agentboard, :mattermost_channel_allowlist, "channel-1")
    Application.put_env(:agentboard, :coordinator_id, "replacement")
    assert {:error, "forbidden", _} = Participation.authorize_local(participant(), "channel-1")
  end
end
