defmodule Agentboard.CoordinatorTriageTest do
  use ExUnit.Case, async: true
  alias Agentboard.CoordinatorTriage.Metadata

  defp metadata(category \\ "status", source \\ nil),
    do: %{"version" => 1, "category" => category, "attention" => "routine", "source" => source}

  test "classification depends only on validated explicit intent" do
    for category <- ~w(status next_work needs_judgment) do
      value = metadata(category)
      assert Metadata.valid?(value)
      assert Metadata.classification(value) == category

      assert Metadata.classification(Map.put(value, "attention", "captain")) ==
               "captain_addressed"
    end

    assert Metadata.classification(nil) == "unclassified"

    refute Metadata.valid?(
             Map.put(metadata(), "body", "needs judgment @captain [coop-fallback source=ci]")
           )
  end

  test "metadata exact keys, types, version and integer boundaries" do
    for value <- [
          nil,
          [],
          "status",
          %{},
          Map.put(metadata(), "version", 1.0),
          Map.put(metadata(), "version", true),
          Map.put(metadata(), "version", 2),
          Map.put(metadata(), "attention", "auto"),
          Map.put(metadata(), "category", "captain_addressed"),
          Map.put(metadata(), "provenance", %{}),
          Map.delete(metadata(), "source")
        ] do
      refute Metadata.valid?(value)
    end

    source = %{
      "kind" => "task_status",
      "task_id" => "fixture",
      "task_event_id" => 1,
      "task_revision" => 1
    }

    assert Metadata.valid?(metadata("status", source))

    for field <- ~w(task_event_id task_revision),
        value <- [0, -1, true, "1", 1.0, 9_007_199_254_740_992] do
      refute Metadata.valid?(metadata("status", Map.put(source, field, value)))
    end

    for value <- ["", "a\n", "Capital", String.duplicate("a", 129)] do
      refute Metadata.valid?(metadata("status", Map.put(source, "task_id", value)))
    end
  end

  test "canonical source discriminators are bounded and never normalized" do
    source = %{
      "kind" => "cooperation_event",
      "event_id" => "00000000-0000-0000-0000-000000000001",
      "source_key" => "exact source"
    }

    for category <- ~w(ci conflict) do
      assert Metadata.valid?(metadata(category, source))
      refute Metadata.valid?(metadata(category))

      for key <- ["", "a\n", "a\t", "a\u007f", String.duplicate("a", 241)] do
        refute Metadata.valid?(metadata(category, Map.put(source, "source_key", key)))
      end

      assert Metadata.valid?(metadata(category, Map.put(source, "source_key", " a ")))
      refute Metadata.valid?(metadata(category, Map.put(source, "server_verified", true)))
    end

    assert Metadata.valid?(
             metadata("next_work", %{
               "kind" => "task_assignment",
               "task_id" => "fixture",
               "assignment_revision" => 1
             })
           )

    assert Metadata.valid?(
             metadata("needs_judgment", %{
               "kind" => "decision_request",
               "request_id" => source["event_id"]
             })
           )

    refute Metadata.valid?(metadata("status", source))
  end

  test "new HTTP capabilities are explicit and coordinator reads retain downstream ownership checks" do
    policy = Agentboard.Auth.APIAuthPolicy
    assert policy.boundary(%{plug: AgentboardWeb.CoordinatorTriageController}) == :captain
    coordinator = %{scope: "coordinator", agent_id: "fixture-coordinator"}

    for action <- [:message, :message_triage] do
      route = %{plug: AgentboardWeb.APIController, plug_opts: action}
      assert policy.allowed?(coordinator, route, "GET", %{})
      refute policy.allowed?(coordinator, route, "POST", %{})
    end
  end
end
