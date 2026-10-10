defmodule Agentboard.Mattermost.DecisionConversations.Source do
  @moduledoc "Verified typed routing and metadata-only catch-up owned by the inbound receiver."

  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Mattermost.{Inbound, InboundStore}
  alias Agentboard.Mattermost.DecisionConversations.Payload
  alias Agentboard.Repo

  @fields ~w(id decision_id operation actor_id source repo channel_id root_id recipient_id task_id bot_user_id msg_id payload_hash state post_id post_version post_metadata verified_at duplicate_observed_at)a
  @select Enum.map_join(@fields, ",", fn
            field when field in [:id, :decision_id] -> "d.#{field}::text"
            field -> "d.#{field}"
          end)

  # Looking up a marker never makes the marker authoritative. In particular,
  # copied human props do not suppress ordinary mentions or root-author delivery.
  def route(cfg, post) do
    if post["user_id"] == cfg.bot_id do
      case Payload.intent_id(post) do
        nil -> :ordinary
        id ->
          %{rows: rows} = Repo.statement!("SELECT #{@select} FROM decision_conversation_intents d WHERE d.id=$1", [InboundStore.uuid(id)])
          classify(cfg, post, case rows do [row] -> intent(row); _ -> nil end)
      end
    else
      :ordinary
    end
  end

  @doc false
  def classify(_cfg, _post, nil), do: :ordinary
  def classify(cfg, post, intent) do
    candidate = post["user_id"] == cfg.bot_id and post["user_id"] == intent.bot_user_id and
      Payload.intent_id(post) == intent.id and Inbound.valid_post?(post)

    cond do
      not candidate -> :ordinary
      intent.state == "sent" and not is_nil(intent.verified_at) and is_nil(intent.duplicate_observed_at) and
          intent.source == cfg.source and intent.source == InboundStore.source(cfg) and
          intent.repo == cfg.repo and intent.channel_id == post["channel_id"] and
          intent.root_id == (post["root_id"] || "") and
          intent.post_id == post["id"] and intent.post_version == InboundStore.version(post) and
          Payload.matches?(intent, post) -> {:typed, intent}
      # A known shared-bot candidate has no free-text fanout, including during the
      # pre-201 race or after an edit. Only its original verified version can join.
      true -> :defer
    end
  end

  @doc false
  def attribution(intent) do
    %{agent_id: intent.actor_id, task_id: intent.task_id, msg_id: intent.msg_id,
      kind: if(intent.operation == "notify", do: "ask-user", else: "decision")}
  end

  # Called inside the fenced capture transaction. These row locks preserve the
  # admission boundary against concurrent retirement, revocation or repo changes.
  @doc false
  def recipients(cfg, intent, metadata) do
    history_start = Application.get_env(:agentboard, :mattermost_inbound_history_start_ms)
    stamp = Enum.max(Enum.map(~w(create_at update_at edit_at delete_at), &(metadata[&1] || 0)))
    %{rows: rows} = Repo.statement!("""
    SELECT s.id FROM cooperation_subscriptions s
    JOIN agents a ON a.id=s.id JOIN tasks t ON t.id=$3
    WHERE s.id=$1 AND NOT s.revoked AND a.retired_at IS NULL AND $2=ANY(s.repos)
      AND CASE WHEN position('/' in t.repo)>0 THEN lower(t.repo) ELSE 'carverauto/' || lower(t.repo) END=$2
      AND ($4::bigint IS NOT NULL AND $5::bigint >= $4
        OR $4 IS NULL AND to_timestamp($5::double precision/1000)>=s.enrolled_at)
    FOR SHARE OF s,a,t
    """, [intent.recipient_id, cfg.repo, intent.task_id, history_start, stamp])
    Enum.map(rows, &hd/1)
  end

  # The existing owner revisits verified receipts whose *exact* metadata already
  # arrived. No remote history loop, reconstructed body, or receipt-only capture.
  def recover(cfg, authorized_channels) do
    channels = Enum.filter(authorized_channels, &Inbound.allowed?/1)
    history_start = Application.get_env(:agentboard, :mattermost_inbound_history_start_ms)

    InboundStore.fenced(cfg, fn ->
      if cfg.source != InboundStore.source(cfg), do: Ops.reject("conflict", "Inbound source changed")

      %{rows: rows} = Repo.statement!("""
      SELECT #{@select} FROM decision_conversation_intents d
      JOIN mattermost_post_versions v ON v.source=d.source AND v.channel_id=d.channel_id
        AND v.post_id=d.post_id AND v.version=d.post_version
        AND v.user_id=d.bot_user_id AND v.root_id=d.root_id AND v.delete_at=0
      JOIN cooperation_subscriptions s ON s.id=d.recipient_id AND NOT s.revoked AND d.repo=ANY(s.repos)
      JOIN agents a ON a.id=s.id AND a.retired_at IS NULL
      JOIN tasks t ON t.id=d.task_id
        AND CASE WHEN position('/' in t.repo)>0 THEN lower(t.repo) ELSE 'carverauto/' || lower(t.repo) END=d.repo
      CROSS JOIN LATERAL (SELECT GREATEST(
        COALESCE((d.post_metadata->>'create_at')::bigint,0), COALESCE((d.post_metadata->>'update_at')::bigint,0),
        COALESCE((d.post_metadata->>'edit_at')::bigint,0), COALESCE((d.post_metadata->>'delete_at')::bigint,0)) AS value) stamp
      WHERE d.state='sent' AND d.verified_at IS NOT NULL AND d.duplicate_observed_at IS NULL AND d.source=$1 AND d.repo=$2
        AND d.bot_user_id=$3 AND d.channel_id=ANY($4::text[])
        AND ($5::bigint IS NOT NULL AND stamp.value >= $5
          OR $5 IS NULL AND to_timestamp(stamp.value::double precision/1000)>=s.enrolled_at)
        AND NOT EXISTS (SELECT 1 FROM mattermost_inbox i WHERE i.source=d.source
          AND i.channel_id=d.channel_id AND i.post_id=d.post_id AND i.version=d.post_version
          AND i.worker_id=d.recipient_id)
      ORDER BY d.verified_at,d.id LIMIT 100 FOR SHARE OF d,v SKIP LOCKED
      """, [cfg.source, cfg.repo, cfg.bot_id, channels, history_start])

      Enum.reduce(rows, 0, fn row, count ->
        case InboundStore.capture_retained(cfg, intent(row)) do
          {:ok, true} -> count + 1
          {:ok, false} -> count
          {:error, :owner_expired} -> Ops.reject("conflict", "Inbound owner expired or replaced")
          {:error, _} -> Ops.reject("unavailable", "Inbound metadata recovery unavailable")
        end
      end)
    end)
  end

  defp intent(row), do: @fields |> Enum.zip(row) |> Map.new()
end
