defmodule Agentboard.Delivery.BranchFlow.SettingsTest do
  use ExUnit.Case, async: true
  alias Agentboard.Delivery.BranchFlow.Settings

  defp request(pins \\ ["fixture/zeta", "fixture/alpha"]),
    do: %{"revision" => 0, "idempotency_key" => "save-1", "pinned_repositories" => pins}

  test "valid replacements retain the exact intended pin order and receipt request" do
    data = request()
    assert {:ok, ^data} = Settings.validate(data)
    assert {:ok, _} = Settings.validate(request([]))
    assert {:ok, _} = Settings.validate(request(Enum.map(1..5, &"fixture/repo-#{&1}")))

    data = request() |> Map.put("revision", 2_147_483_646)
    assert {:ok, ^data} = Settings.validate(data)
  end

  test "full replacement requires exact known fields and a bounded integer revision" do
    for field <- Map.keys(request()) do
      assert {:error, "invalid_input", message} = Settings.validate(Map.delete(request(), field))
      assert message =~ "Exact"
    end

    for field <-
          ~w(actor changed_by captain proof branch_flow_admin integration_ref roles enabled),
        do:
          assert(
            {:error, "invalid_input", _} = Settings.validate(Map.put(request(), field, true))
          )

    assert {:error, "invalid_input", _} = Settings.validate(Map.put(request(), :revision, 0))

    for value <- [-1, 2_147_483_647, 0.0, "0", nil, true] do
      assert {:error, "invalid_input", message} =
               Settings.validate(Map.put(request(), "revision", value))

      assert message =~ "revision"
    end

    for value <- [nil, [], "", true, 1],
        do: assert({:error, "invalid_input", _} = Settings.validate(value))
  end

  test "pin shape rejects duplicates, six pins and malformed canonical identities" do
    for value <- [nil, %{}, "fixture/repo", false] do
      assert {:error, "invalid_input", message} =
               Settings.validate(Map.put(request(), "pinned_repositories", value))

      assert message =~ "pinned_repositories"
    end

    assert {:error, "invalid_input", _} =
             Settings.validate(request(["fixture/repo", "fixture/repo"]))

    assert {:error, "invalid_input", _} =
             Settings.validate(request(Enum.map(1..6, &"fixture/repo-#{&1}")))

    for value <- [
          nil,
          1,
          %{},
          "",
          " ",
          "Fixture/repo",
          "fixture/Repo",
          " fixture/repo",
          "fixture/repo ",
          "fixture/repo.git/extra",
          "fixture/.",
          "fixture/..",
          ".owner/repo",
          "https://github.com/fixture/repo",
          "fixture/repo\n",
          "fixture/repo\t",
          "fixture/rep\u202Eo",
          "fixture/répo",
          "fixture/" <> String.duplicate("r", 249),
          <<255>>
        ] do
      assert {:error, "invalid_input", message} = Settings.validate(request([value]))
      assert message =~ "pinned_repositories"
    end

    assert {:ok, _} = Settings.validate(request(["fixture/" <> String.duplicate("r", 248)]))
    assert {:ok, _} = Settings.validate(request(["owner-name/repo_name.v2"]))
  end

  test "idempotency keys are exact bounded strings and are never silently normalized" do
    for value <- [
          nil,
          1,
          %{},
          "",
          " ",
          " save-1",
          "save-1 ",
          "key\n",
          "key\t",
          "a\u202Eb",
          <<255>>,
          String.duplicate("k", 129)
        ] do
      assert {:error, "invalid_input", message} =
               Settings.validate(Map.put(request(), "idempotency_key", value))

      assert message =~ "idempotency_key"
    end

    for value <- [String.duplicate("k", 128), String.duplicate("é", 64)] do
      data = Map.put(request(), "idempotency_key", value)
      assert {:ok, ^data} = Settings.validate(data)
    end

    assert {:error, "invalid_input", _} =
             Settings.validate(Map.put(request(), "idempotency_key", String.duplicate("é", 65)))
  end

  test "unverified or expired authority is rejected before any database read" do
    for capability <- [
          nil,
          true,
          %{role: :captain},
          %{"proof" => "forged", "expires" => 9_999_999_999},
          %{"proof" => "expired", "expires" => 0}
        ] do
      assert {:error, "forbidden", _} = Settings.show(capability)
      assert {:error, "forbidden", _} = Settings.replace(capability, request())
      assert {:error, "forbidden", _} = Settings.reconcile(capability, request())
    end
  end
end
