defmodule Agentboard.Delivery.RepositoryRolesTest do
  use ExUnit.Case, async: true
  require Phoenix.LiveViewTest
  alias Agentboard.Delivery.{RepositoryMetadata, BranchFlow.RepositoryRoles}
  @stamp ~U[2026-10-10 02:00:00Z]

  test "verified default role is exact, source-qualified and never branch health" do
    role = RepositoryRoles.qualify("fixture/repo", metadata(), @stamp, true)
    assert role.available and role.fresh
    assert role.default_ref == "release/東京"
    assert role.retained_default_ref == "release/東京"
    assert role.source_generation == 4
    assert role.source_run_id == "fixture/repo/17"
    assert role.source_run_generation == 2
    assert role.source_url == "https://github.com/fixture/repo/actions/runs/17"
    assert role.health == "unknown"
    assert role.reason == nil
  end

  test "a newer reservation invalidates old role even before collection completes" do
    role = RepositoryRoles.qualify("fixture/repo", %{metadata() | generation: 5}, @stamp, true)
    refute role.available
    refute role.fresh
    assert role.default_ref == nil
    assert role.retained_default_ref == "release/東京"
    assert role.reason == "collection_pending_or_superseded"
  end

  test "disabled, stale, future, missing and mismatched sources remain unknown" do
    for {row, enabled, reason} <- [
          {metadata(), false, "observation_disabled"},
          {%{metadata() | observed_at: DateTime.add(@stamp, -181)}, true, "stale"},
          {%{metadata() | observed_at: DateTime.add(@stamp, 1)}, true, "future_observation"},
          {nil, true, "not_retained"},
          {%{metadata() | id: "other/repo"}, true, "source_mismatch"},
          {%{metadata() | source_run_id: "other/repo/17"}, true, "source_mismatch"},
          {%{metadata() | source_run_generation: 0}, true, "source_mismatch"},
          {%{metadata() | source_generation: nil}, true, "source_mismatch"},
          {%{metadata() | observed_at: nil}, true, "source_mismatch"},
          {%{metadata() | default_ref: "bad\nref"}, true, "source_mismatch"}
        ] do
      role = RepositoryRoles.qualify("fixture/repo", row, @stamp, enabled)
      refute role.available
      refute role.fresh
      assert role.default_ref == nil
      assert role.reason == reason
      assert role.health == "unknown"
    end

    assert RepositoryRoles.qualify(
             "fixture/repo",
             %{metadata() | observed_at: DateTime.add(@stamp, -180)},
             @stamp,
             true
           ).fresh
  end

  test "default ref validation keeps exact case and Unicode but rejects invalid Git ref shapes" do
    for ref <- ["main", "release/東京", "Feature/Case", "v1.2"] do
      assert RepositoryMetadata.valid_ref?(ref), ref
    end

    for ref <- [
          nil,
          [],
          "",
          "@",
          "/main",
          "main/",
          "a//b",
          ".hidden",
          "a/.hidden",
          "a.lock",
          "a..b",
          "a@{b",
          "a b",
          "a~b",
          "a^b",
          "a:b",
          "a?b",
          "a*b",
          "a[b",
          "a\\b",
          "a.",
          "a\t",
          "a\0",
          String.duplicate("a", 256)
        ] do
      refute RepositoryMetadata.valid_ref?(ref), inspect(ref)
    end
  end

  test "mixed-case workflow identities retain canonical roles without rewriting source provenance" do
    source = %{metadata() | source_run_id: "Fixture/Repo/17"}
    role = RepositoryRoles.qualify("fixture/repo", source, @stamp, true)
    assert role.available
    assert role.source_run_id == "Fixture/Repo/17"
    assert role.source_url == "https://github.com/fixture/repo/actions/runs/17"
  end

  test "read failure removes every current role claim while preserving historical source" do
    current = RepositoryRoles.qualify("fixture/repo", metadata(), @stamp, true)
    role = RepositoryRoles.degrade(current)
    refute role.available
    refute role.fresh
    assert role.default_ref == nil
    assert role.retained_default_ref == current.default_ref
    assert role.source_run_id == current.source_run_id
    assert role.reason == "read_unavailable"
    assert role.health == "unknown"
    assert RepositoryRoles.degrade(nil) == nil
  end

  test "another default producer prevents unified current-default claims while preserving workflow evidence" do
    role = RepositoryRoles.qualify("fixture/repo", metadata(), @stamp, true, true)
    refute role.available
    refute role.fresh
    assert role.default_ref == nil
    assert role.retained_default_ref == "release/東京"
    assert role.source_run_id == "fixture/repo/17"
    assert role.reason == "default_source_contract_pending"
  end

  test "metadata loading has an explicit seven-repository cap" do
    assert RepositoryRoles.load([], @stamp) == %{}

    assert_raise FunctionClauseError, fn ->
      RepositoryRoles.load(Enum.map(1..8, &"fixture/repo#{&1}"), @stamp)
    end
  end

  test "role component preserves unknown health, provenance and stale last-known text" do
    role = RepositoryRoles.qualify("fixture/repo", metadata(), @stamp, true)

    html =
      Phoenix.LiveViewTest.render_component(&AgentboardWeb.BranchFlowComponents.default_role/1,
        role: role,
        as_of: @stamp
      )

    assert html =~ "Default branch:"
    assert html =~ "release/東京"
    assert html =~ "workflow-observed provider role"
    assert html =~ "Current branch health unknown"
    assert html =~ "repository generation 4/4"
    assert html =~ "run generation 2"
    assert html =~ role.source_url
    refute html =~ "Default branch unknown"

    stale = RepositoryRoles.qualify("fixture/repo", %{metadata() | generation: 5}, @stamp, true)

    html =
      Phoenix.LiveViewTest.render_component(&AgentboardWeb.BranchFlowComponents.default_role/1,
        role: stale,
        as_of: @stamp
      )

    assert html =~ "Default branch unknown"
    assert html =~ "Last workflow-observed default: release/東京 (not current)"
    assert html =~ "repository generation 4/5"
    refute html =~ "workflow-observed provider role"
  end

  defp metadata do
    %{
      id: "fixture/repo",
      generation: 4,
      source_generation: 4,
      default_ref: "release/東京",
      source_run_id: "fixture/repo/17",
      source_run_generation: 2,
      observed_at: DateTime.add(@stamp, -60),
      last_error: nil
    }
  end
end
