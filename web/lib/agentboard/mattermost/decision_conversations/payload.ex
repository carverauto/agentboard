defmodule Agentboard.Mattermost.DecisionConversations.Payload do
  @moduledoc "Versioned semantic payload projection, distinct from the full inbound version hash."
  alias Agentboard.Mattermost.InboundHTTP

  @keys ~w(agent_id task_id kind msg_id agentboard_retry_key agentboard_decision_id agentboard_decision_intent agentboard_conversation_version agentboard_inbox_id agentboard_inbox_version)
  @required ~w(agent_id task_id kind msg_id agentboard_retry_key agentboard_decision_id agentboard_decision_intent)

  def intent_id(post) when is_map(post) do
    case get_in(post, ["props", "agentboard_decision_intent"]) do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, ^value} -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def intent_id(_), do: nil

  def digest(post) when is_map(post) do
    props = post["props"]
    root = post["root_id"] || ""

    if InboundHTTP.segment?(post["channel_id"]) and
         (root == "" or InboundHTTP.segment?(root)) and is_binary(post["message"]) and
         String.valid?(post["message"]) and byte_size(post["message"]) <= 65_536 and
         not String.contains?(post["message"], <<0>>) and is_map(props) and
         props["agentboard_conversation_version"] == 1 and
         Enum.all?(@required, &(is_binary(props[&1]) and byte_size(props[&1]) in 1..128)) and
         Enum.all?(
           ~w(agentboard_inbox_id agentboard_inbox_version),
           &(is_nil(props[&1]) or is_binary(props[&1]))
         ) do
      [1, post["channel_id"], root, post["message"], Enum.map(@keys, &[&1, props[&1]])]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  def digest(_), do: nil

  def matches?(intent, post) when is_map(intent) and is_map(post) do
    digest(post) == intent.payload_hash and post["channel_id"] == intent.channel_id and
      (post["root_id"] || "") == intent.root_id and post["user_id"] == intent.bot_user_id and
      (post["delete_at"] || 0) == 0 and post["file_ids"] in [nil, []] and
      intent_id(post) == intent.id
  end

  def matches?(_, _), do: false

  def make(intent, body) do
    props = %{
      "agent_id" => intent.actor_id,
      "task_id" => intent.task_id,
      "kind" => if(intent.operation == "notify", do: "ask-user", else: "decision"),
      "msg_id" => intent.msg_id,
      "agentboard_retry_key" => intent.request_key,
      "agentboard_decision_id" => intent.decision_id,
      "agentboard_decision_intent" => intent.id,
      "agentboard_conversation_version" => 1
    }

    props =
      if intent.operation == "reply",
        do:
          Map.merge(props, %{
            "agentboard_inbox_id" => intent.inbox_id,
            "agentboard_inbox_version" => intent.inbox_version
          }),
        else: props

    %{
      "channel_id" => intent.channel_id,
      "root_id" => intent.root_id,
      "message" => "[#{intent.actor_id} · #{intent.task_id}]\n" <> body,
      "props" => props
    }
  end
end
