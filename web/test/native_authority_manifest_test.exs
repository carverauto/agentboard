defmodule Agentboard.NativeAuthority.ManifestTest do
  use ExUnit.Case, async: true
  alias Agentboard.NativeAuthority.Manifest

  defp manifest do
    %{
      "manifest_version" => 1,
      "id" => "fixture-approval",
      "worker_id" => "fixture-worker",
      "host_id" => "fixture-host",
      "enrollment_revision" => 123,
      "binding_epoch" => 1,
      "session_id" => "fixture-session",
      "pane_id" => "fixture-pane",
      "socket_path" => "/invented/socket",
      "initialize_approved" => true,
      "endpoint" => %{
        "serverId" => "fixture",
        "endpointId" => "fixture",
        "generation" => "",
        "profile" => "codex-durable-advisory-v1",
        "nativeVersion" => "0.162.0",
        "protocolSource" => "rust-v0.162.0",
        "schemaSha256" => String.duplicate("a", 64),
        "experimentalApi" => true,
        "queueApi" => true
      },
      "recipient" => %{
        "threadId" => "11111111-1111-4111-8111-111111111111",
        "identityKind" => "durable-conversation-v1",
        "enrollmentRevision" => 123,
        "bindingEpoch" => 1,
        "persistent" => true,
        "topLevel" => true
      },
      "peer" => %{
        "pid" => 1234,
        "uid" => 1000,
        "bootId" => "22222222-2222-4222-8222-222222222222",
        "startTicks" => 3456,
        "executableSha256" => String.duplicate("b", 64)
      }
    }
  end

  test "closed nested descriptor, exact integer type and bounded peer" do
    m = manifest()
    assert Manifest.valid?(m)

    for changed <- [
          Map.put(m, "extra", nil),
          Map.delete(m, "initialize_approved"),
          Map.put(m, "manifest_version", 1.0),
          put_in(m, ["recipient", "bindingEpoch"], 1.0),
          put_in(m, ["peer", "uid"], -1),
          put_in(m, ["peer", "startTicks"], 9_007_199_254_740_992),
          put_in(m, ["endpoint", "generation"], "invented"),
          put_in(m, ["endpoint", "unknown"], true),
          Map.put(m, "socket_path", "/invented//socket"),
          Map.put(m, "socket_path", "/invented/../socket"),
          Map.put(m, "host_id", "host\n"),
          Map.put(m, "pane_id", "雪")
        ],
        do: refute(Manifest.valid?(changed))
  end

  test "host and binding strings match the frozen callback byte budget" do
    for field <- ~w(host_id session_id pane_id) do
      assert Manifest.valid?(Map.put(manifest(), field, String.duplicate("a", 240)))
      refute Manifest.valid?(Map.put(manifest(), field, String.duplicate("a", 241)))
    end
  end

  test "sorted canonical JSON does not HTML escape strings" do
    assert Manifest.canonical(%{"z" => true, "a" => %{"v" => "<>&/\"", "i" => 123}}) ==
             ~s({"a":{"i":123,"v":"<>&/\\\""},"z":true})

    assert Manifest.sha256(%{"b" => 2, "a" => 1}) ==
             "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777"
  end

  test "full manifest hash matches the Go contract vector" do
    m =
      manifest()
      |> Map.merge(%{
        "worker_id" => "worker-native",
        "enrollment_revision" => 1_791_750_000_000_000,
        "binding_epoch" => 3,
        "socket_path" => "/tmp/fixture-native.sock"
      })
      |> put_in(["endpoint", "serverId"], "fixture-server")
      |> put_in(["endpoint", "endpointId"], "fixture-endpoint")
      |> put_in(["recipient", "enrollmentRevision"], 1_791_750_000_000_000)
      |> put_in(["recipient", "bindingEpoch"], 3)
      |> put_in(["peer", "pid"], 42)
      |> put_in(["peer", "uid"], 0)
      |> put_in(["peer", "startTicks"], 12345)

    assert Manifest.valid?(m)

    assert Manifest.sha256(m) ==
             "a6a45399ab74964c650659ee0a0460d2b7698dd39ea264507eb416a5e1537b80"
  end

  test "scoped generated Ash resource snapshots match current attributes" do
    actual =
      AshPostgres.MigrationGenerator.take_snapshots(Agentboard.Cooperation, Agentboard.Repo, [
        Agentboard.Cooperation.Binding,
        Agentboard.Cooperation.NativeApproval
      ])
      |> Jason.encode!()
      |> Jason.decode!()

    expected =
      Application.app_dir(:agentboard, "priv/native_authority_resource_snapshots.json")
      |> File.read!()
      |> Jason.decode!()

    assert Enum.map(actual, & &1["table"]) == Enum.map(expected, & &1["table"])

    # Ash hashes inspect(snapshot), whose representation is not a wire contract
    # across test/code-loading contexts. Compare every generated schema field.
    for {current, recorded} <- Enum.zip(actual, expected),
        {key, value} <- current,
        key != "hash" do
      assert value == recorded[key],
             "#{current["table"]}.#{key}: #{inspect(value, limit: :infinity)} != #{inspect(recorded[key], limit: :infinity)}"
    end
  end

  test "enrollment and binding identity must agree exactly across descriptor" do
    m = manifest()
    refute Manifest.valid?(put_in(m, ["recipient", "enrollmentRevision"], 124))
    refute Manifest.valid?(put_in(m, ["recipient", "bindingEpoch"], 2))
    refute Manifest.valid?(put_in(m, ["recipient", "persistent"], false))
    refute Manifest.valid?(put_in(m, ["recipient", "topLevel"], false))
    refute Manifest.valid?(put_in(m, ["recipient", "identityKind"], "incarnation"))
  end
end
