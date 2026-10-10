defmodule Agentboard.Mattermost.DecisionConversationSourceTest do
  use ExUnit.Case, async: true

  alias Agentboard.Mattermost.InboundStore
  alias Agentboard.Mattermost.DecisionConversations.{Payload, Source}

  defp fixture(operation \\ "notify") do
    cfg = %{base_url: "http://mattermost.invalid", repo: "fixture/roundtrip", bot_id: "shared-bot"}
    cfg = Map.put(cfg, :source, InboundStore.source(cfg))
    intent = %{
      id: "00000000-0000-0000-0000-000000000001",
      decision_id: "00000000-0000-0000-0000-000000000002",
      operation: operation, actor_id: "worker-a", recipient_id: "coordinator",
      source: cfg.source, repo: cfg.repo, channel_id: "room", root_id: if(operation == "reply", do: "root", else: ""),
      task_id: "fixture-task", bot_user_id: cfg.bot_id, msg_id: "typed-message",
      request_key: "fixture-key", inbox_id: "00000000-0000-0000-0000-000000000003",
      inbox_version: String.duplicate("a", 64), state: "sent", verified_at: ~U[2026-01-01 00:00:00Z], duplicate_observed_at: nil
    }
    post = intent |> Payload.make("@coordinator question mentions @unrelated-worker") |> Map.merge(%{
      "id" => "post", "user_id" => cfg.bot_id, "create_at" => 1000, "update_at" => 1000,
      "edit_at" => 0, "delete_at" => 0, "file_ids" => [], "type" => ""
    })
    intent = Map.merge(intent, %{payload_hash: Payload.digest(post), post_id: post["id"],
      post_version: InboundStore.version(post), post_metadata: Map.take(post, ~w(id user_id channel_id root_id create_at update_at edit_at delete_at))})
    {cfg, intent, post}
  end

  test "only the original verified source yields the pinned typed recipient" do
    for operation <- ["notify", "reply"] do
      {cfg, intent, post} = fixture(operation)
      assert {:typed, ^intent} = Source.classify(cfg, post, intent)
      assert intent.recipient_id == "coordinator"
      assert Source.attribution(intent) == %{agent_id: "worker-a", task_id: "fixture-task",
        msg_id: "typed-message", kind: if(operation == "notify", do: "ask-user", else: "decision")}
    end
  end

  test "known duplicate evidence suppresses the otherwise exact sent source" do
    {cfg, intent, post} = fixture()
    assert {:typed, ^intent} = Source.classify(cfg, post, intent)
    duplicated = %{intent | duplicate_observed_at: ~U[2026-01-01 00:00:01Z]}
    assert :defer == Source.classify(cfg, post, duplicated)
    assert duplicated.post_id == intent.post_id
    assert duplicated.post_version == intent.post_version
  end

  test "unverified known shared-bot candidates defer rather than expanding mentions" do
    {cfg, intent, post} = fixture()
    for state <- ["prepared", "submitting", "uncertain", "blocked"] do
      pending = Map.merge(intent, %{state: state, post_id: nil, post_version: nil, verified_at: nil})
      assert :defer == Source.classify(cfg, post, pending)
    end
    assert :defer == Source.classify(cfg, post, %{intent | verified_at: nil})
  end

  test "human copies, wrong actual bot, unknown and malformed markers stay ordinary" do
    {cfg, intent, post} = fixture()
    assert :ordinary == Source.classify(cfg, post, nil)
    assert :ordinary == Source.classify(cfg, Map.put(post, "user_id", "human"), intent)
    assert :ordinary == Source.classify(cfg, Map.put(post, "user_id", "elastic-bot"), intent)
    assert :ordinary == Source.classify(cfg, post, %{intent | bot_user_id: nil})
    for marker <- [nil, "not-a-uuid", "00000000-0000-0000-0000-000000000004"] do
      assert :ordinary == Source.classify(cfg, put_in(post, ["props", "agentboard_decision_intent"], marker), intent)
    end
  end

  test "same-time edits and non-owned prop changes never inherit canonical association" do
    {cfg, intent, post} = fixture()
    edited = Map.put(post, "message", post["message"] <> " edited @another-worker")
    assert edited["update_at"] == post["update_at"]
    assert :defer == Source.classify(cfg, edited, intent)

    extra = put_in(post, ["props", "server_added"], "changed")
    assert Payload.digest(extra) == intent.payload_hash
    refute InboundStore.version(extra) == intent.post_version
    assert :defer == Source.classify(cfg, extra, intent)
  end

  test "source fingerprint, destination, author, post id and exact version all remain pinned" do
    {cfg, intent, post} = fixture("reply")
    for {key, value} <- [source: String.duplicate("f", 64), repo: "other/repo", channel_id: "other-room",
                         root_id: "other-root", post_id: "other-post", post_version: String.duplicate("0", 64),
                         payload_hash: String.duplicate("1", 64)] do
      assert :defer == Source.classify(cfg, post, Map.put(intent, key, value))
    end
    assert :defer == Source.classify(%{cfg | base_url: "http://changed.invalid"}, post, intent)
    assert :defer == Source.classify(cfg, Map.put(post, "delete_at", 1000), intent)
    assert :defer == Source.classify(cfg, Map.put(post, "file_ids", ["attachment"]), intent)
  end

  test "an edited payload cannot qualify even when presented with its edited version" do
    {cfg, intent, post} = fixture()
    post = Map.put(post, "message", "changed body @another-worker")
    assert :defer == Source.classify(cfg, post, %{intent | post_version: InboundStore.version(post)})
  end
end
