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
