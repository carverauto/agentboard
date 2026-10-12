defmodule Agentboard.Mattermost.ChatSpool do
  @moduledoc """
  Protected outbound spool for generic agent chat (OpenSpec 5.2).

  Every send is recorded here before the network call, so an accepted-post/
  lost-response can be reconciled by its `msg_id` post prop instead of being
  posted again. The body is retained only while the outcome is unresolved:
  a verified or definitively rejected send drops it immediately, and expiry
  drops it for everything else. The table is not an Ash resource, not
  versioned, not BM25-indexed and never returned by an API: receipts expose
  metadata only, so the spool cannot become a second inbox.
  """
  alias Agentboard.Repo

  @default_ttl_s 86_400
  @max_ttl_s 2_592_000
  @purge_batch 500

  # A `submitting` row older than this lost its request process (restart,
  # crash or timeout) and must reconcile before anything else happens.
  @submit_lease_s 120

  @columns ~w(msg_id agent_id channel_id root_id task_id kind retry_key recipient_id state reason resolution post_id duplicate_post_ids attempts created_at submitted_at resolved_at expires_at updated_at body_retained)a
  @select """
  msg_id, agent_id, channel_id, root_id, task_id, kind, retry_key, recipient_id, state, reason,
  resolution, post_id, duplicate_post_ids, attempts, created_at, submitted_at, resolved_at,
  expires_at, updated_at, body IS NOT NULL
  """

  def ttl_s do
    case Application.get_env(:agentboard, :chat_spool_ttl_s, @default_ttl_s) do
      seconds when is_integer(seconds) and seconds >= 1 -> min(seconds, @max_ttl_s)
      _ -> @default_ttl_s
    end
  end

  def submit_lease_s, do: @submit_lease_s

  def digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  # Records a new submission, or returns the row that already owns this
  # agent's retry key. Uniqueness is enforced by the partial index, so two
  # racing requests converge on one row without an advisory lock.
  def reserve(attrs) do
    %{rows: rows} =
      Repo.statement!(
        """
        INSERT INTO conversation_spool (msg_id, agent_id, channel_id, root_id, task_id, kind,
          retry_key, recipient_id, body, body_sha256, state, attempts, created_at, submitted_at,
          expires_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'submitting', 1, clock_timestamp(),
          clock_timestamp(), clock_timestamp() + ($11::integer * interval '1 second'), clock_timestamp())
        ON CONFLICT (agent_id, retry_key) WHERE retry_key IS NOT NULL DO NOTHING
        RETURNING #{@select}
        """,
        [
          attrs.msg_id,
          attrs.agent_id,
          attrs.channel_id,
          attrs.root_id,
          attrs.task_id,
          attrs.kind,
          attrs.retry_key,
          attrs.recipient_id,
          attrs.body,
          digest(attrs.body),
          ttl_s()
        ]
      )

    case rows do
      [row] -> {:new, to_map(row)}
      [] -> {:existing, by_key(attrs.agent_id, attrs.retry_key)}
    end
  end

  # A retry-key send that was adopted from remote history (or a pre-spool
  # post) is recorded as already sent, so later retries need no search.
  def record_adopted(attrs, post_id) do
    Repo.statement!(
      """
      INSERT INTO conversation_spool (msg_id, agent_id, channel_id, root_id, task_id, kind,
        retry_key, recipient_id, body, body_sha256, state, resolution, post_id, attempts,
        created_at, resolved_at, expires_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULL, $9, 'sent', 'adopted_remote', $10, 0,
        clock_timestamp(), clock_timestamp(), clock_timestamp() + ($11::integer * interval '1 second'),
        clock_timestamp())
      ON CONFLICT DO NOTHING
      """,
      [
        attrs.msg_id,
        attrs.agent_id,
        attrs.channel_id,
        attrs.root_id,
        attrs.task_id,
        attrs.kind,
        attrs.retry_key,
        attrs.recipient_id,
        digest(attrs.body),
        post_id,
        ttl_s()
      ]
    )

    :ok
  end

  def fetch(msg_id) when is_binary(msg_id) do
    %{rows: rows} =
      Repo.statement!("SELECT #{@select} FROM conversation_spool WHERE msg_id=$1", [msg_id])

    case rows do
      [row] -> to_map(row)
      [] -> nil
    end
  end

  def by_key(_agent_id, nil), do: nil

  def by_key(agent_id, retry_key) do
    %{rows: rows} =
      Repo.statement!(
        "SELECT #{@select} FROM conversation_spool WHERE agent_id=$1 AND retry_key=$2",
        [agent_id, retry_key]
      )

    case rows do
      [row] -> to_map(row)
      [] -> nil
    end
  end

  # The retained body is read only to resubmit the caller's own send.
  def body(msg_id) do
    %{rows: rows} =
      Repo.statement!("SELECT body FROM conversation_spool WHERE msg_id=$1", [msg_id])

    case rows do
      [[body]] when is_binary(body) -> {:ok, body}
      _ -> :expired
    end
  end

  def list(agent_id, states, limit) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT #{@select} FROM conversation_spool
        WHERE agent_id=$1 AND state = ANY($2)
        ORDER BY created_at DESC, msg_id LIMIT $3
        """,
        [agent_id, states, limit]
      )

    Enum.map(rows, &to_map/1)
  end

  # Every transition is fenced on the state the caller observed, so a racing
  # request or a stale process never overwrites a newer outcome.
  def mark_sent(msg_id, from_states, post_id, resolution \\ nil, duplicates \\ []) do
    transition(
      msg_id,
      from_states,
      """
      state='sent', body=NULL, post_id=$3, reason=NULL, resolution=COALESCE($4, resolution),
      duplicate_post_ids=$5, resolved_at=clock_timestamp()
      """,
      [post_id, resolution, duplicates]
    )
  end

  def mark_failed(msg_id, from_states, reason) do
    transition(
      msg_id,
      from_states,
      "state='failed', body=NULL, reason=$3, resolved_at=clock_timestamp()",
      [reason]
    )
  end

  def mark_uncertain(msg_id, from_states, reason) do
    transition(msg_id, from_states, "state='uncertain', reason=$3", [reason])
  end

  def mark_abandoned(msg_id, from_states) do
    transition(
      msg_id,
      from_states,
      "state='abandoned', body=NULL, resolution='abandoned', resolved_at=clock_timestamp()",
      []
    )
  end

  # Re-arms an existing row for one more network attempt. The resolution
  # records why (for example a manual retry that accepts a possible duplicate).
  def resubmit(msg_id, from_states, body, resolution) do
    transition(
      msg_id,
      from_states,
      """
      state='submitting', body=$3, body_sha256=$4, reason=NULL, resolution=COALESCE($5, resolution),
      attempts=attempts+1, submitted_at=clock_timestamp(), resolved_at=NULL
      """,
      [body, digest(body), resolution]
    )
  end

  defp transition(msg_id, from_states, assignments, params) do
    %{rows: rows} =
      Repo.statement!(
        """
        UPDATE conversation_spool SET #{assignments}, updated_at=clock_timestamp()
        WHERE msg_id=$1 AND state = ANY($2)
        RETURNING #{@select}
        """,
        [msg_id, from_states | params]
      )

    case rows do
      [row] -> {:ok, to_map(row)}
      [] -> {:stale, fetch(msg_id)}
    end
  end

  def stale_submission?(%{state: "submitting", updated_at: updated_at}) do
    DateTime.diff(DateTime.utc_now(), updated_at) >= @submit_lease_s
  end

  def stale_submission?(_), do: false

  # Expiry purges content, never evidence of an unresolved outcome: terminal
  # rows are deleted (their receipt lives in Mattermost or the caller's
  # response), while unresolved rows become body-free `expired` markers that
  # still block a blind replay of their retry key until explicitly abandoned.
  def purge_expired do
    %{num_rows: deleted} =
      Repo.statement!(
        """
        DELETE FROM conversation_spool WHERE msg_id IN (
          SELECT msg_id FROM conversation_spool
          WHERE expires_at <= clock_timestamp() AND state IN ('sent', 'failed', 'abandoned')
          ORDER BY expires_at LIMIT $1 FOR UPDATE SKIP LOCKED)
        """,
        [@purge_batch]
      )

    %{num_rows: expired} =
      Repo.statement!(
        """
        UPDATE conversation_spool SET state='expired', body=NULL,
          reason=COALESCE(reason, 'spool_expired'), updated_at=clock_timestamp()
        WHERE msg_id IN (
          SELECT msg_id FROM conversation_spool
          WHERE expires_at <= clock_timestamp() AND state IN ('submitting', 'uncertain')
          ORDER BY expires_at LIMIT $1 FOR UPDATE SKIP LOCKED)
        """,
        [@purge_batch]
      )

    {:ok, %{deleted: deleted, expired: expired}}
  end

  # Metadata-only receipt: never the body, never a credential.
  def public(nil), do: nil

  def public(row) do
    %{
      "msg_id" => row.msg_id,
      "state" => row.state,
      "reason" => row.reason,
      "resolution" => row.resolution,
      "post_id" => row.post_id,
      "duplicate_post_ids" => row.duplicate_post_ids,
      "channel_id" => row.channel_id,
      "root_id" => row.root_id,
      "task_id" => row.task_id,
      "kind" => row.kind,
      "retry_key" => row.retry_key,
      "recipient_id" => row.recipient_id,
      "attempts" => row.attempts,
      "body_retained" => row.body_retained,
      "created_at" => row.created_at,
      "submitted_at" => row.submitted_at,
      "resolved_at" => row.resolved_at,
      "expires_at" => row.expires_at
    }
  end

  defp to_map(row), do: @columns |> Enum.zip(row) |> Map.new()
end
