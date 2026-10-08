defmodule Agentboard.Mattermost.InboundStore do
  @moduledoc "Fenced metadata-only version ledger. No Mattermost message bodies, tokens or arbitrary props are persisted."
  alias Agentboard.Repo
  alias Agentboard.Board.Operations, as: Ops

  def source(cfg), do: :crypto.hash(:sha256, cfg.base_url <> "\n" <> cfg.repo) |> Base.encode16(case: :lower)
  def uuid(id), do: Ecto.UUID.dump!(id)

  def claim(cfg) do
    run = Ash.UUID.generate()
    %{num_rows: n} = Repo.statement!("""
    INSERT INTO mattermost_inbound_runs(source,repo,run_id,expires_at,connected,reason)
    VALUES($1,$2,$3,clock_timestamp()+interval '30 seconds',false,'connecting')
    ON CONFLICT(source) DO UPDATE SET run_id=excluded.run_id,expires_at=excluded.expires_at,connected=false,reason='connecting'
    WHERE mattermost_inbound_runs.expires_at<=clock_timestamp()
    """, [source(cfg), cfg.repo, uuid(run)])
    if n == 1, do: {:ok, Map.merge(cfg, %{source: source(cfg), run: run})}, else: {:error, :another_owner}
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :store_unavailable}
  end

  def renew(cfg, connected, reason) do
    %{num_rows: n} = Repo.statement!("""
    UPDATE mattermost_inbound_runs SET expires_at=clock_timestamp()+interval '30 seconds',connected=$3,reason=$4
    WHERE source=$1 AND run_id=$2 AND expires_at>clock_timestamp()
    """, [cfg.source, uuid(cfg.run), connected, reason])
    {:ok, n == 1}
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :store_unavailable}
  end

  def release(cfg, reason, delay \\ 0) do
    Repo.statement!("UPDATE mattermost_inbound_runs SET connected=false,reason=$3,expires_at=clock_timestamp()+$4::integer*interval '1 second' WHERE source=$1 AND run_id=$2", [cfg.source, uuid(cfg.run), reason, delay])
    :ok
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> :ok
  end

  def fenced(cfg, fun) do
    case Ops.transaction(fn ->
      %{rows: rows} = Repo.statement!("SELECT source FROM mattermost_inbound_runs WHERE source=$1 AND run_id=$2 AND expires_at>clock_timestamp() FOR SHARE", [cfg.source, uuid(cfg.run)])
      if rows == [], do: Ops.reject("conflict", "Inbound owner expired or replaced")
      fun.()
    end) do
      {:ok, value} -> {:ok, value}
      {:error, "conflict", _} -> {:error, :owner_expired}
      {:error, _, _} -> {:error, :store_unavailable}
      {:error, _} -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  end

  def coverage(cfg, channel, page, complete, reason) do
    fenced(cfg, fn ->
      Repo.statement!("""
      INSERT INTO mattermost_channel_recovery(source,channel_id,run_id,page,history_complete,reason,checked_at)
      VALUES($1,$2,$3,COALESCE($4,0),$5,$6,clock_timestamp()) ON CONFLICT(source,channel_id) DO UPDATE
      SET run_id=excluded.run_id,page=COALESCE($4,mattermost_channel_recovery.page),history_complete=excluded.history_complete,reason=excluded.reason,checked_at=excluded.checked_at
      """, [cfg.source, channel, uuid(cfg.run), page, complete, reason])
      :ok
    end)
  end

  # Canonical ordered fields avoid JSON map ordering and exclude receiver metadata.
  def version(post) do
    fields = Enum.map(~w(id channel_id user_id root_id create_at update_at edit_at delete_at message type props file_ids), &post[&1])
    canonical = canonical(fields)
    :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
  end
  defp canonical(v) when is_map(v), do: v |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> [k, canonical(v)] end)
  defp canonical(v) when is_list(v), do: Enum.map(v, &canonical/1)
  defp canonical(v), do: v

  def capture(cfg, post, recipients, attribution) do
    version = version(post)
    case fenced(cfg, fn ->
      %{rows: existing} = Repo.statement!("SELECT 1 FROM mattermost_post_versions WHERE source=$1 AND channel_id=$2 AND post_id=$3 AND version=$4", [cfg.source, post["channel_id"], post["id"], version])
      if existing == [] do
        %{rows: [[count]]} = Repo.statement!("SELECT count(*) FROM mattermost_post_versions WHERE source=$1", [cfg.source])
        if count >= 100_000 do
          {:capacity_reached, version}
        else
          store_version(cfg, post, recipients, attribution, version)
        end
      else
        store_version(cfg, post, recipients, attribution, version)
      end
    end) do
      {:ok, {:stored, version}} -> {:ok, version}
      {:ok, {:capacity_reached, _version}} -> {:error, :metadata_capacity_reached}
      {:error, :owner_expired} = error -> error
      {:error, :store_unavailable} = error -> error
    end
  end

  defp store_version(cfg, post, recipients, attribution, version) do
    Repo.statement!("""
    INSERT INTO mattermost_post_versions(source,channel_id,post_id,version,user_id,root_id,update_at,delete_at,observed_at)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,clock_timestamp()) ON CONFLICT DO NOTHING
    """, [cfg.source, post["channel_id"], post["id"], version, post["user_id"], post["root_id"] || "", post["update_at"] || post["create_at"] || 0, post["delete_at"] || 0])
    Enum.each(recipients, fn id ->
      Repo.statement!("""
      INSERT INTO mattermost_inbox(id,source,channel_id,post_id,version,worker_id,repo,task_id,sender_agent_id,msg_id,kind,created_at)
      VALUES(gen_random_uuid(),$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,clock_timestamp()) ON CONFLICT DO NOTHING
      """, [cfg.source, post["channel_id"], post["id"], version, id, cfg.repo, attribution[:task_id], attribution[:agent_id], attribution[:msg_id], attribution[:kind] || "note"])
    end)
    {:stored, version}
  end

  def known_posts(cfg, channel) do
    %{rows: rows} = Repo.statement!("SELECT DISTINCT post_id FROM mattermost_post_versions WHERE source=$1 AND channel_id=$2 ORDER BY post_id", [cfg.source, channel])
    {:ok, Enum.map(rows, &hd/1)}
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :store_unavailable}
  end

  def page(subscription, data) do
    {last_seq, high} = decode_cursor(data["cursor"])
    high = high || high_water()
    %{rows: rows} = Repo.statement!("""
    SELECT i.seq,i.id::text,i.source,i.channel_id,i.post_id,i.version,v.user_id,v.root_id,v.delete_at,i.task_id,i.sender_agent_id,i.msg_id,i.kind
    FROM mattermost_inbox i JOIN mattermost_post_versions v USING(source,channel_id,post_id,version)
    WHERE i.worker_id=$1 AND i.repo=ANY($2::text[]) AND i.handled_at IS NULL AND i.seq>$3 AND i.seq<=$4
    ORDER BY i.seq LIMIT 51
    """, [subscription.id, subscription.repos, last_seq, high])
    items = Enum.take(rows, 50) |> Enum.map(fn [_seq, id, source, channel, post, version, user, root, deleted, task, sender, msg, kind] ->
      %{id: id, source: source, channel_id: channel, post_id: post, version: version, user_id: user, root_id: root, delete_at: deleted, task_id: task, sender_agent_id: sender, msg_id: msg, kind: kind}
    end)
    %{rows: coverage} = Repo.statement!("""
    SELECT c.channel_id,c.page,c.history_complete,c.reason,c.checked_at,r.connected AND r.expires_at>clock_timestamp(),r.reason
    FROM mattermost_channel_recovery c JOIN mattermost_inbound_runs r USING(source)
    WHERE r.repo=ANY($1::text[]) ORDER BY c.source,c.channel_id LIMIT 1001
    """, [subscription.repos])
    %{rows: streams} = Repo.statement!("SELECT source,connected AND expires_at>clock_timestamp(),reason FROM mattermost_inbound_runs WHERE repo=ANY($1::text[]) ORDER BY source LIMIT 21", [subscription.repos])
    %{stream_states: Enum.map(streams, fn [source, connected, reason] -> %{source: source, live_connected: connected, reason: reason} end), items: items, next_cursor: if(length(rows) > 50, do: encode_cursor(rows |> Enum.take(50) |> List.last() |> hd(), high)), enabled: Agentboard.Mattermost.Inbound.enabled?(),
      coverage_truncated: length(coverage) > 1000, coverage: Enum.map(Enum.take(coverage, 1000), fn [channel, page, complete, reason, checked, connected, stream_reason] ->
        %{channel_id: channel, next_page: page, history_complete: complete, caught_up: false, incomplete_reason: reason, checked_at: checked, live_connected: connected, stream_reason: stream_reason}
      end)}
  end

  defp decode_cursor(nil), do: {0, nil}
  defp decode_cursor(""), do: {0, nil}
  defp decode_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 128 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [last, high]} <- Jason.decode(json),
         true <- is_integer(last) and is_integer(high) and last >= 0 and high >= last do
      {last, high}
    else
      _ -> Ops.reject("invalid_input", "Opaque inbox cursor required")
    end
  end
  defp decode_cursor(_), do: Ops.reject("invalid_input", "Opaque inbox cursor required")

  defp encode_cursor(last, high), do: Base.url_encode64(Jason.encode!([last, high]), padding: false)

  defp high_water do
    %{rows: [[max]]} = Repo.statement!("SELECT COALESCE(MAX(seq),0) FROM mattermost_inbox", [])
    max
  end

  def read(subscription, data) do
    unless Ecto.UUID.cast(data["id"]) != :error and is_binary(data["version"]),
      do: Ops.reject("invalid_input", "Exact inbox id/version required")
    %{rows: rows} = Repo.statement!("""
    SELECT i.source,i.channel_id,i.post_id,i.version,v.user_id,v.root_id,v.delete_at,i.task_id,i.sender_agent_id,i.msg_id,i.kind
    FROM mattermost_inbox i JOIN mattermost_post_versions v USING(source,channel_id,post_id,version)
    WHERE i.id=$1 AND i.version=$2 AND i.worker_id=$3 AND i.repo=ANY($4::text[])
    """, [uuid(data["id"]), data["version"], subscription.id, subscription.repos])
    case rows do
      [[source, channel, post, version, user, root, deleted, task, sender, msg, kind]] ->
        %{items: [%{id: data["id"], source: source, channel_id: channel, post_id: post, version: version, user_id: user, root_id: root, delete_at: deleted, task_id: task, sender_agent_id: sender, msg_id: msg, kind: kind}]}
      _ -> Ops.reject("forbidden", "Exact version is not this worker's inbox item")
    end
  end

  def acknowledge(subscription, data) do
    items = data["items"]
    unless is_list(items) and length(items) in 1..50 and Enum.all?(items, fn item ->
      is_map(item) and Ecto.UUID.cast(item["id"]) != :error and is_binary(item["version"]) and Regex.match?(~r/^[0-9a-f]{64}$/, item["version"])
    end), do: Ops.reject("invalid_input", "Exact bounded inbox id/version pairs required")
    Enum.each(items, fn item ->
      %{num_rows: n} = Repo.statement!("UPDATE mattermost_inbox SET handled_at=COALESCE(handled_at,clock_timestamp()),handled_model=COALESCE(handled_model,$5),handled_harness=COALESCE(handled_harness,$6) WHERE id=$1 AND version=$2 AND worker_id=$3 AND repo=ANY($4::text[])", [uuid(item["id"]), item["version"], subscription.id, subscription.repos, subscription.model, subscription.harness])
      if n != 1, do: Ops.reject("forbidden", "Exact version is not this worker's inbox item")
    end)
    %{handled: Enum.map(items, & &1["id"])}
  end
end
