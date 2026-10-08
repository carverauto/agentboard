defmodule AgentboardWeb.DecisionPanelTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "findings disclosures keep per-decision hook identities while rendered content changes" do
    for revision <- 1..3 do
      records = Enum.map(["one", "two"], &decision(&1, revision))
      html = render_component(&AgentboardWeb.DecisionPanel.waiting/1,
        records: records, unavailable: false, captain: nil)

      # This is generated DOM consumed by LiveView, not template source.
      details =
        Regex.scan(~r/<details\s+([^>]+)>/, html, capture: :all_but_first)
        |> Enum.map(fn [attributes] ->
          Regex.scan(~r/([\w-]+)="([^"]*)"/, attributes, capture: :all_but_first)
          |> Map.new(fn [key, value] -> {key, value} end)
          |> Map.take(["id", "phx-hook", "phx-update"])
        end)

      assert details == [
        %{"id" => "decision-findings-one", "phx-hook" => "CompletedCard"},
        %{"id" => "decision-findings-two", "phx-hook" => "CompletedCard"}
      ]
      assert html =~ "findings version #{revision}"
    end
  end

  defp decision(id, revision) do
    %{
      "id" => id, "task_id" => "fixture-task-#{id}", "requester_id" => "fixture-seat",
      "kind" => "ask_user_gate", "gate_ref" => "fixture/review", "status" => "open",
      "requester_stale" => false, "held_by_decision" => true,
      "created_at" => "2026-01-01T00:00:00Z", "claim_expires_at" => nil,
      "question" => "Fixture question", "findings" => "findings version #{revision}",
      "options" => [], "recommendation" => nil, "answer" => nil
    }
  end
end
