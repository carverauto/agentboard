defmodule Agentboard.CoordinatorProtocolTest do
  use ExUnit.Case, async: false
  alias Agentboard.Coordinator.{Contract, JSON}
  alias Agentboard.Auth.APIAuthPolicy, as: Policy
  alias AgentboardWeb.{APIController, CoordinatorController, DecisionController}

  @id "11111111-1111-1111-1111-111111111111"
  @other "22222222-2222-2222-2222-222222222222"
  @version String.duplicate("a", 64)

  defp item(id \\ @id), do: %{"id" => id, "version" => @version, "disposition" => "reviewed"}
  defp ack(items \\ [item()]), do: %{"retry_key" => "retry-1", "items" => items}

  test "ack is strict, bounded and order normalized without dropping semantics" do
    assert {:ok, first} = Contract.ack(ack([item(), item(@other)]))
    assert {:ok, reverse} = Contract.ack(ack([item(@other), item()]))
    assert first == reverse

    assert {:ok, changed} =
             Contract.ack(ack([Map.put(item(), "disposition", "escalated"), item(@other)]))

    refute first.hash == changed.hash

    for invalid <- [
          nil,
          [],
          %{},
          Map.put(ack(), "extra", 1),
          Map.put(ack(), "retry_key", ""),
          Map.put(ack(), "retry_key", " \n"),
          Map.put(ack(), "retry_key", String.duplicate("é", 65)),
          Map.put(ack(), "retry_key", "key\0"),
          ack([]),
          ack(List.duplicate(item(), 2)),
          ack([Map.put(item(), "extra", true)]),
          ack([Map.delete(item(), "version")]),
          ack([Map.put(item(), "version", String.upcase(@version))]),
          ack([Map.put(item(), "disposition", "answered")]),
          ack([Map.put(item(), "id", @id <> "\n")]),
          ack(
            Enum.map(1..21, fn n ->
              item("00000000-0000-0000-0000-" <> String.pad_leading("#{n}", 12, "0"))
            end)
          )
        ] do
      assert {:error, "invalid_input", _} = Contract.ack(invalid), inspect(invalid)
    end
  end

  test "heartbeat accepts only existing own status/task semantics" do
    assert :ok = Contract.heartbeat(%{"status" => "busy", "task" => "task-1"})
    assert :ok = Contract.heartbeat(%{"status" => "idle"})

    for data <- [
          %{},
          nil,
          %{"status" => "working"},
          %{"status" => "idle", "backend" => "herdr"},
          %{"status" => "idle", "task" => "../other"},
          %{"status" => "idle", "model" => "other"}
        ] do
      assert {:error, "invalid_input", _} = Contract.heartbeat(data)
    end
  end

  test "pagination measures full encoded bytes and binds cursor options and principal" do
    rows =
      Enum.map(1..4, fn n ->
        %{
          "id" => if(n == 1, do: @id, else: @other),
          "created_at" => "2026-10-10T00:00:00Z",
          "summary" => String.duplicate("x", 1900)
        }
      end)

    assert {:ok, options} = Contract.query(%{"limit" => "3", "max_bytes" => "4096"}, "coord")
    assert {:ok, page} = Contract.page(rows, "coord", options)
    assert byte_size(Jason.encode!(page)) <= 4096
    assert length(page.items) in 1..2
    refute page.complete

    assert {:ok, _} =
             Contract.query(
               %{"limit" => "3", "max_bytes" => "4096", "cursor" => page.next_cursor},
               "coord"
             )

    for query <- [
          %{"cursor" => page.next_cursor},
          %{"limit" => "4", "max_bytes" => "4096", "cursor" => page.next_cursor},
          %{"limit" => "3", "max_bytes" => "8192", "cursor" => page.next_cursor}
        ] do
      assert {:error, "invalid_input", _} = Contract.query(query, "coord")
    end

    assert {:error, "invalid_input", _} =
             Contract.query(
               %{"limit" => "3", "max_bytes" => "4096", "cursor" => page.next_cursor},
               "other"
             )

    assert {:ok, empty} = Contract.page([], "coord", options)
    assert empty.complete and empty.next_cursor == nil and empty.items == []

    assert {:error, "invalid_input", _} =
             Contract.page(
               [
                 %{
                   "id" => @id,
                   "created_at" => "2026-10-10T00:00:00Z",
                   "summary" => String.duplicate("x", 5000)
                 }
               ],
               "coord",
               options
             )
  end

  test "invalid queries never silently restart or widen traversal" do
    for query <- [
          %{"unknown" => "1"},
          %{"limit" => "0"},
          %{"limit" => "101"},
          %{"limit" => "+1"},
          %{"limit" => "01"},
          %{"limit" => 1},
          %{"max_bytes" => "4095"},
          %{"max_bytes" => "65537"},
          %{"cursor" => ""},
          %{"cursor" => "bad"},
          %{"cursor" => String.duplicate("x", 4097)},
          %{"cursor" => Base.url_encode64("{}", padding: false)}
        ] do
      assert {:error, "invalid_input", _} = Contract.query(query, "coord")
    end

    for created <- [
          nil,
          1,
          [],
          %{},
          true,
          "0000-01-01T00:00:00Z",
          "2026-02-30T00:00:00Z",
          "2026-10-10T00:00:00-05:00",
          "10000-01-01T00:00:00Z"
        ] do
      cursor =
        [1, "coord", 20, 16_384, created, @id]
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert {:error, "invalid_input", _} = Contract.query(%{"cursor" => cursor}, "coord")
    end
  end

  test "new JSON decoder rejects duplicate keys recursively without changing valid JSON" do
    assert JSON.decode!(~s({"items":[{"a":1}],"b":null})) == %{
             "items" => [%{"a" => 1}],
             "b" => nil
           }

    assert_raise ArgumentError, fn -> JSON.decode!(~s({"retry_key":"a","retry_key":"b"})) end
    assert_raise ArgumentError, fn -> JSON.decode!(~s({"items":[{"id":"a","id":"b"}]})) end
  end

  test "runner route allowlist never inherits ordinary-agent or chat capabilities" do
    for scope <- ~w(agent coordinator coordinator_participant coordinator_runner) do
      principal = %{scope: scope, agent_id: "coord", channel_ids: ["channel"]}

      for {action, method} <- [tick: "GET", show: "GET", ack: "POST", heartbeat: "POST"] do
        assert Policy.allowed?(
                 principal,
                 %{plug: CoordinatorController, plug_opts: action},
                 method,
                 %{}
               ) == (scope == "coordinator_runner")
      end

      refute Policy.allowed?(
               principal,
               %{plug: CoordinatorController, plug_opts: :tick},
               "POST",
               %{}
             )
    end

    for {controller, action, method} <- [
          {APIController, :mutate, "POST"},
          {APIController, :heartbeat, "POST"},
          {APIController, :messages, "GET"},
          {DecisionController, :show, "GET"},
          {DecisionController, :mutate, "POST"}
        ] do
      refute Policy.allowed?(
               %{scope: "coordinator_runner"},
               %{plug: controller, plug_opts: action},
               method,
               %{}
             )
    end

    assert Policy.valid_channel_grant?("coordinator_runner", [])
    refute Policy.valid_channel_grant?("coordinator_runner", ["channel"])
    assert Policy.boundary(%{plug: CoordinatorController, plug_opts: :tick}) == :agent
  end

  test "domain independently rejects absent principal and off/observe modes before DB access" do
    old_mode = Application.get_env(:agentboard, :agent_auth_mode)
    old_id = Application.get_env(:agentboard, :coordinator_id)

    on_exit(fn ->
      Application.put_env(:agentboard, :agent_auth_mode, old_mode)
      Application.put_env(:agentboard, :coordinator_id, old_id)
    end)

    Application.put_env(:agentboard, :coordinator_id, "coord")
    principal = %{scope: "coordinator_runner", agent_id: "coord", credential_id: @id}

    for mode <- ~w(off observe) do
      Application.put_env(:agentboard, :agent_auth_mode, mode)
      assert {:error, "forbidden", _} = Agentboard.Coordinator.tick(principal, %{})
      assert {:error, "forbidden", _} = Agentboard.Coordinator.show(principal, @id)
      assert {:error, "forbidden", _} = Agentboard.Coordinator.acknowledge(principal, ack())

      assert {:error, "forbidden", _} =
               Agentboard.Coordinator.heartbeat(principal, %{"status" => "idle"})
    end

    Application.put_env(:agentboard, :agent_auth_mode, "enforce")
    assert {:error, "forbidden", _} = Agentboard.Coordinator.tick(nil, %{})

    assert {:error, "forbidden", _} =
             Agentboard.Coordinator.tick(%{principal | agent_id: "other"}, %{})
  end
end
