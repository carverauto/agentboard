defmodule Agentboard.FleetLoadoutTest do
  use ExUnit.Case, async: true
  alias Agentboard.FleetLoadout

  defp seat(id \\ "seat-a", agent \\ "agent-a"),
    do: %{
      "seat_id" => id,
      "agent_id" => agent,
      "harness" => "fixture-harness",
      "desired_host_id" => "host-unverified",
      "desired_model" => "future-model",
      "desired_effort" => "future-effort",
      "scope_revision" => 1
    }

  defp request(seats \\ [seat()]),
    do: %{"revision" => 0, "idempotency_key" => "save-1", "seats" => seats}

  test "normalizes ordering and desired text without assuming a catalog" do
    padded =
      seat()
      |> Map.put("desired_model", " future-model ")
      |> Map.put("desired_effort", " future-effort ")

    data = request([seat("seat-z", "agent-z"), padded]) |> Map.put("idempotency_key", " save-1 ")
    assert {:ok, normalized} = FleetLoadout.validate(data)
    assert normalized["seats"] == [seat(), seat("seat-z", "agent-z")]
    assert normalized["idempotency_key"] == "save-1"
    assert {:ok, _} = FleetLoadout.validate(request([]))

    assert {:ok, _} =
             FleetLoadout.validate(request(Enum.map(1..32, &seat("seat-#{&1}", "agent-#{&1}"))))
  end

  test "exact bounded full replacement only" do
    for field <- Map.keys(request()),
        do:
          assert(
            {:error, "invalid_input", _} = FleetLoadout.validate(Map.delete(request(), field))
          )

    for field <-
          ~w(enabled activate seat_count host_status catalog_status role captain fleet_admin),
        do:
          assert(
            {:error, "invalid_input", _} = FleetLoadout.validate(Map.put(request(), field, true))
          )

    for value <- [-1, 2_147_483_647, 0.0, "0", nil],
        do:
          assert(
            {:error, "invalid_input", _} =
              FleetLoadout.validate(Map.put(request(), "revision", value))
          )

    for value <- [nil, %{}, "", List.duplicate(seat(), 33)],
        do:
          assert(
            {:error, "invalid_input", _} =
              FleetLoadout.validate(Map.put(request(), "seats", value))
          )

    assert {:error, "invalid_input", _} = FleetLoadout.validate(request([seat(), seat("seat-b")]))

    assert {:error, "invalid_input", _} =
             FleetLoadout.validate(request([seat(), seat("seat-a", "agent-b")]))
  end

  test "seat references reject partial copies, scope arrays and control characters" do
    for field <- Map.keys(seat()),
        do:
          assert(
            {:error, "invalid_input", _} =
              FleetLoadout.validate(request([Map.delete(seat(), field)]))
          )

    for field <-
          ~w(allowed_repos allowed_labels required_labels capabilities enabled scope observed_model),
        do:
          assert(
            {:error, "invalid_input", _} =
              FleetLoadout.validate(request([Map.put(seat(), field, [])]))
          )

    for field <- ~w(seat_id agent_id desired_host_id harness desired_model desired_effort),
        value <- [nil, 1, %{}, "", " ", "bad\n", "bad\ttext", "bad\u202Etext", <<255>>] do
      assert {:error, "invalid_input", _} =
               FleetLoadout.validate(request([Map.put(seat(), field, value)]))
    end

    for {field, max} <- [{"harness", 128}, {"desired_model", 256}, {"desired_effort", 64}] do
      assert {:ok, _} =
               FleetLoadout.validate(
                 request([Map.put(seat(), field, String.duplicate("a", max))])
               )

      assert {:error, "invalid_input", _} =
               FleetLoadout.validate(
                 request([Map.put(seat(), field, String.duplicate("a", max + 1))])
               )

      assert {:error, "invalid_input", _} =
               FleetLoadout.validate(
                 request([Map.put(seat(), field, String.duplicate("é", max))])
               )
    end

    for value <- [0, -1, 2_147_483_648, nil, 1.0],
        do:
          assert(
            {:error, "invalid_input", _} =
              FleetLoadout.validate(request([Map.put(seat(), "scope_revision", value)]))
          )

    for value <- [nil, "", "x\n", String.duplicate("x", 129)],
        do:
          assert(
            {:error, "invalid_input", _} =
              FleetLoadout.validate(Map.put(request(), "idempotency_key", value))
          )
  end

  test "unverified proof is rejected before touching database" do
    for proof <- [
          nil,
          true,
          %{"proof" => "forged", "expires" => 9_999_999_999},
          %{role: :captain}
        ] do
      assert {:error, "forbidden", _} = FleetLoadout.show("fleet", proof)
      assert {:error, "forbidden", _} = FleetLoadout.replace("fleet", proof, request())
    end
  end
end
