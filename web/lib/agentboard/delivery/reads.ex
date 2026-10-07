defmodule Agentboard.Delivery.Reads do
  @moduledoc "Bounded dashboard reads; a last-known projection is never fresh verified green."
  alias Agentboard.Delivery.{PullRequest, PollState, Obligation, CISnapshot}
  alias Agentboard.Board.Operations, as: Ops
  require Ash.Query

  def list(params \\ %{}) do
    Ops.transaction(fn ->
      cursor = params["cursor"] || ""

      if not is_binary(cursor) or byte_size(cursor) > 200,
        do: Ops.reject("invalid_input", "Invalid PR cursor")

      rows =
        PullRequest
        |> Ash.Query.filter(id > ^cursor)
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(21)
        |> Ash.read!()

      selected = Enum.take(rows, 20)

      %{
        prs: Enum.map(selected, &record/1),
        next_cursor: if(length(rows) > 20, do: List.last(selected).id, else: nil)
      }
    end)
  end

  def review(urls) when is_list(urls) and length(urls) <= 20 do
    Ops.transaction(fn ->
      identities =
        Enum.flat_map(urls, fn url ->
          case Agentboard.Delivery.Inventory.canonical(url) do
            {:ok, pr} -> [{url, pr.id}]
            _ -> []
          end
        end)

      ids = Enum.map(identities, &elem(&1, 1))

      states =
        PullRequest
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.limit(20)
        |> Ash.read!()
        |> Map.new(fn pr -> {pr.id, ci_projection(pr)} end)

      Map.new(identities, fn {url, id} -> {url, states[id]} end)
    end)
  end

  def detail(id) do
    Ops.transaction(fn ->
      pr = Ops.fetch!(PullRequest, id, "PR not found")
      base = record(pr)

      sources =
        Agentboard.Delivery.TaskLink
        |> Ash.Query.filter(pull_request_id == ^id)
        |> Ash.read!()
        |> Enum.map(&Ops.public/1)

      %{rows: tables} =
        Agentboard.Repo.statement!("SELECT to_regclass('delivery_ci_snapshots') IS NOT NULL", [])

      history =
        if tables == [[true]] do
          %{rows: rows} =
            Agentboard.Repo.statement!(
              "SELECT payload,head_sha,base_sha,ci_state,observed_at FROM delivery_ci_snapshots WHERE pull_request_id=$1 ORDER BY observed_at DESC LIMIT 20",
              [id]
            )

          Enum.map(rows, fn [payload, head, base, state, observed] ->
            %{
              payload: payload,
              head_sha: head,
              base_sha: base,
              ci_state: state,
              observed_at: observed
            }
          end)
        else
          []
        end

      Map.merge(base, %{sources: sources, observations: history})
    end)
  end

  def health(id) do
    binding = Ash.get!(Agentboard.Cooperation.Binding, id, not_found_error?: false)
    subscription = Ash.get!(Agentboard.Cooperation.Subscription, id, not_found_error?: false)

    if binding && subscription do
      %{rows: [[pending, received, handled, oldest]]} =
        Agentboard.Repo.statement!(
          "SELECT count(*) FILTER (WHERE state='pending'),count(*) FILTER (WHERE state='received'),count(*) FILTER (WHERE state='handled'),min(created_at) FILTER (WHERE state IN ('pending','received')) FROM cooperation_deliveries WHERE worker_id=$1",
          [id]
        )

      attempt =
        if binding.active_attempt_id,
          do: Ash.get!(Agentboard.Cooperation.Attempt, binding.active_attempt_id)

      expired =
        if attempt && attempt.status == "reserved" do
          batch = Ash.get!(Agentboard.Cooperation.Batch, attempt.batch_id)
          DateTime.compare(batch.lease_expires_at, Ops.now()) != :gt
        else
          false
        end

      %{
        binding: Ops.public(binding),
        paused: subscription.paused,
        revoked: subscription.revoked,
        enabled: Agentboard.Cooperation.Runtime.enabled?(subscription),
        pending: pending,
        received: received,
        handled: handled,
        oldest_pending_at: oldest,
        connector_fresh:
          not is_nil(binding.reported_at) and DateTime.diff(Ops.now(), binding.reported_at) <= 90,
        uncertainty: !!attempt and (attempt.status == "uncertain" or expired)
      }
    end
  end

  defp record(pr) do
    s = Ash.get!(PollState, pr.id, not_found_error?: false)

    o =
      Obligation
      |> Ash.Query.filter(pull_request_id == ^pr.id)
      |> Ash.Query.sort(episode: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!()

    %{
      pr: Ops.public(pr),
      poll: if(s, do: Ops.public(s)),
      overdue:
        !!o and is_nil(o.resolved_at) and DateTime.compare(o.next_reminder_at, Ops.now()) != :gt,
      obligation: if(o, do: Ops.public(o)),
      worker: if(o && o.responsible_id, do: health(o.responsible_id))
    }
    |> Map.merge(ci_projection(pr, s))
  end

  defp ci_projection(pr),
    do: ci_projection(pr, Ash.get!(PollState, pr.id, not_found_error?: false))

  defp ci_projection(_pr, s) do
    fresh =
      s && s.observed_at && DateTime.diff(Ops.now(), s.observed_at) <= 180 &&
        s.last_error in [nil, "policy_unknown"]

    state =
      cond do
        is_nil(s) or is_nil(s.observed_at) -> "unknown"
        not fresh -> "stale"
        s.ci_state == "passing" and s.last_error == "policy_unknown" -> "unknown"
        true -> s.ci_state
      end

    snapshot = if s && s.snapshot_id, do: Ash.get!(CISnapshot, s.snapshot_id)

    draft =
      if snapshot && snapshot.head_sha == s.head_sha && snapshot.observed_at == s.observed_at &&
           is_boolean(snapshot.payload["draft"]), do: snapshot.payload["draft"]

    %{ci_state: state, fresh: !!fresh, observed_at: if(s, do: s.observed_at), draft: draft}
  end
end
