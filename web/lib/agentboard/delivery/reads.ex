defmodule Agentboard.Delivery.Reads do
  @moduledoc "Bounded dashboard reads; a last-known projection is never fresh verified green."
  alias Agentboard.Delivery.{PullRequest, PollState, Obligation, CISnapshot}
  alias Agentboard.Board.Operations, as: Ops
  require Ash.Query
  require Ecto.Query

  def list(params \\ %{}) do
    Ops.transaction(fn ->
      cursor = params["cursor"] || ""

      if not is_binary(cursor) or byte_size(cursor) > 200,
        do: Ops.reject("invalid_input", "Invalid PR cursor")

      query = PullRequest |> Ash.Query.filter(id > ^cursor)

      query =
        if params["show_terminal"] == "true",
          do: query,
          else: Ash.Query.filter(query, not exists(poll_state, lifecycle in ["merged", "closed"]))

      rows =
        query
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(21)
        |> Ash.read!()

      selected = Enum.take(rows, 20)

      %{
        prs: Enum.map(selected, &record/1),
        github_budget: budget(),
        default_branch_health: Agentboard.Delivery.WorkflowMonitor.health(),
        next_cursor: if(length(rows) > 20, do: List.last(selected).id, else: nil)
      }
    end)
  end

  @doc "Shared persisted provider-budget projection; performs no provider I/O."
  def budget do
    b = Ash.get!(Agentboard.Delivery.ProviderBudget, "github")
    stamp = Ops.now()
    capacity = min(b.capacity, 60)

    %{rows: [[carried]]} =
      Agentboard.Repo.statement!(
        "SELECT COALESCE(sum(remaining),0)::bigint FROM delivery_poll_credits WHERE expires_at>clock_timestamp()",
        []
      )

    %{
      capacity: capacity,
      remaining:
        if(DateTime.compare(b.reset_at, stamp) != :gt,
          do: max(0, capacity - carried),
          else: min(b.remaining, capacity)
        ),
      reset_at: b.reset_at,
      blocked_until: b.blocked_until,
      provider_blocked: !!b.blocked_until and DateTime.compare(b.blocked_until, stamp) == :gt
    }
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
        |> Map.new(fn pr ->
          {pr.id,
           Map.put(
             ci_projection(pr),
             :duplicate_of,
             Agentboard.Delivery.Duplicates.projection(pr.id)
           )}
        end)

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

      Map.merge(base, %{sources: sources, observations: history, github_budget: budget()})
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

  defp waiting_decisions(pr_id) do
    %{rows: [[records]]} =
      Agentboard.Repo.statement!(
        """
        SELECT coalesce(jsonb_agg(record ORDER BY created_at,id),'[]'::jsonb) FROM (
          SELECT d.created_at,d.id,jsonb_build_object('id',d.id,'task_id',d.task_id,
            'requester_id',d.requester_id,'status',d.status,
            'requester_stale',(a.last_heartbeat IS NULL OR a.last_heartbeat<=clock_timestamp()-interval '10 minutes')) AS record
          FROM decision_requests d JOIN agents a ON a.id=d.requester_id
          WHERE d.status IN ('open','answered') AND EXISTS(
            SELECT 1 FROM delivery_task_links l WHERE l.task_id=d.task_id AND l.pull_request_id=$1)
          ORDER BY d.created_at,d.id LIMIT 20
        ) waiting
        """,
        [pr_id]
      )

    records
  end

  @doc "Project a bounded preselected page using the authoritative dashboard record."
  def records(prs, opts \\ [])
  def records([], _opts), do: []

  def records(prs, opts) when is_list(prs) and length(prs) <= 20 do
    ids = Enum.map(prs, & &1.id)
    states = read_by_ids(PollState, ids)
    obligations = latest_by_pr(Obligation, ids, :episode)
    rebases = latest_by_pr(Agentboard.Delivery.RebaseFollowUp, ids, :created_at)

    snapshots =
      states
      |> Map.values()
      |> Enum.map(& &1.snapshot_id)
      |> Enum.reject(&is_nil/1)
      |> then(&snapshots_by_ids(&1, Keyword.get(opts, :branch_flow, false)))

    # Retain the authoritative duplicate/worker/delivery projectors. Only skip
    # known-absent findings and reuse identical inputs within this read snapshot.
    findings = read_by_ids(Agentboard.Delivery.DuplicateFinding, ids)

    duplicates =
      Map.new(ids, fn id ->
        {id, if(Map.has_key?(findings, id), do: Agentboard.Delivery.Duplicates.projection(id))}
      end)

    workers =
      ids
      |> Enum.map(&responsible(obligations[&1], rebases[&1]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(&{&1, health(&1)})

    deliveries =
      ids
      |> Enum.map(&repair_tasks(obligations[&1], rebases[&1]))
      |> Enum.uniq()
      |> Map.new(&{&1, follow_up_delivery(&1)})

    expected = expected_bases(prs, states)

    batch = %{
      states: states,
      obligations: obligations,
      rebases: rebases,
      snapshots: snapshots,
      duplicates: duplicates,
      decisions: waiting_decisions_batch(ids),
      workers: workers,
      deliveries: deliveries,
      expected: expected,
      branch_flow: Keyword.get(opts, :branch_flow, false),
      as_of:
        if(Keyword.get(opts, :branch_flow, false), do: Keyword.get_lazy(opts, :as_of, &Ops.now/0))
    }

    Enum.map(prs, &record(&1, batch))
  end

  @doc "Compact, authoritative observations for a bounded branch-flow page; no repair expansion."
  def observations(prs, opts \\ []) when is_list(prs) and length(prs) <= 20 do
    states = read_by_ids(PollState, Enum.map(prs, & &1.id))

    snapshots =
      states
      |> Map.values()
      |> Enum.map(& &1.snapshot_id)
      |> Enum.reject(&is_nil/1)
      |> snapshots_by_ids(true)

    batch = %{
      snapshots: snapshots,
      expected: expected_bases(prs, states),
      branch_flow: true,
      as_of: Keyword.get_lazy(opts, :as_of, &Ops.now/0)
    }

    Enum.map(prs, fn pr ->
      state = states[pr.id]

      %{pr: Ops.public(pr), poll: if(state, do: Agentboard.Delivery.Polling.public_state(state))}
      |> Map.merge(ci_projection(pr, state, batch))
    end)
  end

  defp expected_bases(prs, states) do
    Enum.reduce(prs, %{}, fn pr, acc ->
      state = states[pr.id]

      Map.put_new_lazy(acc, expected_key(pr, state), fn ->
        Agentboard.Delivery.BaseMonitor.expected_sha(
          pr,
          state && state.base_ref,
          state && state.expected_base_sha
        )
      end)
    end)
  end

  defp snapshots_by_ids([], _), do: %{}
  defp snapshots_by_ids(ids, false), do: read_by_ids(CISnapshot, ids)

  defp snapshots_by_ids(ids, true) do
    # Only the selected inspection reads failures, separately and with a SQL cap.
    # Graph pages never transfer the up-to-500-attempt immutable payload.
    Agentboard.Repo.all(
      Ecto.Query.from(snapshot in CISnapshot,
        where: snapshot.id in ^ids,
        limit: ^length(ids),
        select: %{
          id: snapshot.id,
          pull_request_id: snapshot.pull_request_id,
          generation: snapshot.generation,
          observed_at: snapshot.observed_at,
          head_sha: snapshot.head_sha,
          base_sha: snapshot.base_sha,
          payload:
            fragment(
              "jsonb_build_object('head_repo', ?->'head_repo', 'head_ref', ?->'head_ref', 'base_ref', ?->'base_ref', 'base_watch_sha', ?->'base_watch_sha', 'draft', ?->'draft', 'mergeable', ?->'mergeable', 'mergeable_state', ?->'mergeable_state')",
              snapshot.payload,
              snapshot.payload,
              snapshot.payload,
              snapshot.payload,
              snapshot.payload,
              snapshot.payload,
              snapshot.payload
            )
        }
      )
    )
    |> Map.new(&{&1.id, &1})
  end

  defp read_by_ids(_, []), do: %{}

  defp read_by_ids(resource, ids) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.limit(length(ids))
    |> Ash.read!()
    |> Map.new(&{&1.id, &1})
  end

  defp latest_by_pr(resource, ids, field) do
    resource
    |> Ash.Query.filter(pull_request_id in ^ids)
    |> Ash.Query.distinct(:pull_request_id)
    |> Ash.Query.distinct_sort([{field, :desc}])
    |> Ash.Query.limit(length(ids))
    |> Ash.read!()
    |> Map.new(&{&1.pull_request_id, &1})
  end

  defp waiting_decisions_batch(ids) do
    %{rows: rows} =
      Agentboard.Repo.statement!(
        """
        SELECT p.id,coalesce(jsonb_agg(waiting.record ORDER BY waiting.created_at,waiting.id)
          FILTER (WHERE waiting.id IS NOT NULL),'[]'::jsonb)
        FROM unnest($1::text[]) p(id)
        LEFT JOIN LATERAL (
          SELECT d.created_at,d.id,jsonb_build_object('id',d.id,'task_id',d.task_id,
            'requester_id',d.requester_id,'status',d.status,
            'requester_stale',(a.last_heartbeat IS NULL OR a.last_heartbeat<=clock_timestamp()-interval '10 minutes')) AS record
          FROM decision_requests d JOIN agents a ON a.id=d.requester_id
          WHERE d.status IN ('open','answered') AND EXISTS(
            SELECT 1 FROM delivery_task_links l WHERE l.task_id=d.task_id AND l.pull_request_id=p.id)
          ORDER BY d.created_at,d.id LIMIT 20
        ) waiting ON true
        GROUP BY p.id
        """,
        [Enum.uniq(ids)]
      )

    Map.new(rows, fn [id, decisions] -> {id, decisions} end)
  end

  defp from_batch(nil, _, _, load), do: load.()
  defp from_batch(batch, section, key, _), do: Map.fetch!(batch, section)[key]

  defp expected_key(pr, s),
    do: {pr.owner, pr.repo, s && s.base_ref, s && s.expected_base_sha}

  defp responsible(o, rebase), do: (o && o.responsible_id) || (rebase && rebase.responsible_id)

  defp repair_tasks(o, rebase) do
    [o && o.repair_task_id, rebase && rebase.repair_task_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp record(pr, batch \\ nil) do
    s =
      from_batch(batch, :states, pr.id, fn ->
        Ash.get!(PollState, pr.id, not_found_error?: false)
      end)

    o =
      from_batch(batch, :obligations, pr.id, fn ->
        Obligation
        |> Ash.Query.filter(pull_request_id == ^pr.id)
        |> Ash.Query.sort(episode: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!()
      end)

    rebase =
      from_batch(batch, :rebases, pr.id, fn ->
        Agentboard.Delivery.RebaseFollowUp
        |> Ash.Query.filter(pull_request_id == ^pr.id)
        |> Ash.Query.sort(created_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!()
      end)

    responsible = responsible(o, rebase)
    repair_tasks = repair_tasks(o, rebase)

    %{
      duplicate_of:
        from_batch(batch, :duplicates, pr.id, fn ->
          Agentboard.Delivery.Duplicates.projection(pr.id)
        end),
      decisions: from_batch(batch, :decisions, pr.id, fn -> waiting_decisions(pr.id) end),
      pr: Ops.public(pr),
      poll: if(s, do: Agentboard.Delivery.Polling.public_state(s)),
      poll_deferral_age:
        if(s && s.budget_deferred_at,
          do: max(0, DateTime.diff(Ops.now(), s.budget_deferred_at)),
          else: 0
        ),
      overdue:
        !!o and is_nil(o.resolved_at) and DateTime.compare(o.next_reminder_at, Ops.now()) != :gt,
      obligation: if(o, do: Ops.public(o)),
      rebase_follow_up: if(rebase, do: Ops.public(rebase)),
      worker:
        if(responsible,
          do: from_batch(batch, :workers, responsible, fn -> health(responsible) end)
        ),
      follow_up_delivery:
        from_batch(batch, :deliveries, repair_tasks, fn -> follow_up_delivery(repair_tasks) end)
    }
    |> Map.merge(ci_projection(pr, s, batch))
  end

  # Derived per-event delivery mode for open repair tasks: worker when a
  # cooperation delivery exists, inbox_fallback when the single-source
  # canonical message was retained (exact source marker only; markerless
  # notes never count), undeliverable otherwise. Read-only derivation; the
  # marker shape must match Runtime.fallback_marker/1.
  defp follow_up_delivery([]), do: []

  defp follow_up_delivery(repair_tasks) do
    %{rows: rows} =
      Agentboard.Repo.statement!(
        """
        SELECT e.kind, e.source_key, e.task_id, e.created_at,
          (SELECT coalesce(jsonb_agg(jsonb_build_object('worker', d.worker_id, 'state', d.state) ORDER BY d.id), '[]'::jsonb)
             FROM cooperation_deliveries d WHERE d.event_id = e.id) AS deliveries,
          (SELECT m.id FROM messages m WHERE m.task_id = e.task_id AND
             position('[coop-fallback source=' || e.source_key || ']' in m.body) > 0
             ORDER BY m.id LIMIT 1) AS fallback_message_id,
          (SELECT m.recipient_id FROM messages m WHERE m.task_id = e.task_id AND
             position('[coop-fallback source=' || e.source_key || ']' in m.body) > 0
             ORDER BY m.id LIMIT 1) AS fallback_recipient
        FROM cooperation_events e
        WHERE e.task_id = ANY($1) AND e.kind IN ('ci_failure', 'ci_reminder', 'ci_digest', 'pr_conflict')
        ORDER BY e.created_at DESC, e.id DESC LIMIT 20
        """,
        [repair_tasks]
      )

    Enum.map(rows, fn [kind, source_key, task_id, created_at, deliveries, message_id, recipient] ->
      mode =
        cond do
          deliveries != [] -> "worker"
          not is_nil(message_id) -> "inbox_fallback"
          true -> "undeliverable"
        end

      %{
        kind: kind,
        source_key: source_key,
        task_id: task_id,
        event_created_at: created_at,
        mode: mode,
        deliveries: deliveries,
        fallback_message_id: message_id,
        fallback_recipient_id: recipient
      }
    end)
  end

  defp ci_projection(pr),
    do: ci_projection(pr, Ash.get!(PollState, pr.id, not_found_error?: false))

  defp ci_projection(pr, s, batch \\ nil) do
    snapshot =
      if s && s.snapshot_id do
        if batch do
          case Map.fetch(batch.snapshots, s.snapshot_id) do
            {:ok, snapshot} ->
              snapshot

            :error ->
              if(Map.get(batch, :branch_flow, false),
                do: nil,
                else: Ash.get!(CISnapshot, s.snapshot_id)
              )
          end
        else
          Ash.get!(CISnapshot, s.snapshot_id)
        end
      end

    payload = snapshot_payload(s, snapshot)

    expected =
      from_batch(batch, :expected, expected_key(pr, s), fn ->
        Agentboard.Delivery.BaseMonitor.expected_sha(
          pr,
          s && s.base_ref,
          s && s.expected_base_sha
        )
      end)

    # New snapshots bind the branch watch sampled before collection. Keep the
    # original provider base_sha intact; older snapshots retain their old rule.
    observed_base = payload["base_watch_sha"] || (s && s.base_sha)
    fresh = fresh?(s, expected, observed_base, batch && Map.get(batch, :as_of))

    %{
      ci_state: ci_state(s, fresh),
      fresh: fresh,
      observed_at: if(s, do: s.observed_at),
      draft: if(is_boolean(payload["draft"]), do: payload["draft"]),
      mergeable: payload["mergeable"],
      mergeable_state: payload["mergeable_state"],
      merge_state: merge_state(s, payload, fresh),
      base_ref: payload["base_ref"],
      expected_base_sha: expected
    }
    |> then(fn projection ->
      if batch && Map.get(batch, :branch_flow, false),
        do: Map.put(projection, :snapshot_source, snapshot),
        else: projection
    end)
  end

  defp snapshot_payload(s, snapshot) when not is_nil(s) and not is_nil(snapshot) do
    if snapshot.head_sha == s.head_sha and snapshot.base_sha == s.base_sha and
         snapshot.observed_at == s.observed_at, do: snapshot.payload, else: %{}
  end

  defp snapshot_payload(_, _), do: %{}

  defp fresh?(
         %{lifecycle: lifecycle, observed_at: %DateTime{} = observed, last_error: error},
         _expected,
         _observed_base,
         stamp
       )
       when lifecycle in ["merged", "closed"],
       do: DateTime.diff(stamp || Ops.now(), observed) <= 180 and error in [nil, "policy_unknown"]

  defp fresh?(
         %{observed_at: %DateTime{} = observed, last_error: error},
         expected,
         observed_base,
         stamp
       ),
       do:
         DateTime.diff(stamp || Ops.now(), observed) <= 180 and error in [nil, "policy_unknown"] and
           (is_nil(expected) or expected == observed_base)

  defp fresh?(_, _, _, _), do: false

  defp ci_state(nil, _), do: "unknown"
  defp ci_state(%{observed_at: nil}, _), do: "unknown"

  defp ci_state(%{lifecycle: lifecycle, ci_state: state}, _)
       when lifecycle in ["merged", "closed"],
       do: state

  defp ci_state(_, false), do: "stale"
  defp ci_state(%{ci_state: "passing", last_error: "policy_unknown"}, _), do: "unknown"
  defp ci_state(s, _), do: s.ci_state

  defp merge_state(%{lifecycle: lifecycle}, _, _) when lifecycle in ["merged", "closed"],
    do: "not_applicable"

  defp merge_state(%{observed_at: %DateTime{}}, _, false), do: "stale"
  defp merge_state(_, %{"mergeable" => nil}, _), do: "unknown"
  defp merge_state(_, %{"mergeable" => false, "mergeable_state" => "dirty"}, _), do: "conflicting"

  defp merge_state(_, %{"mergeable_state" => state}, _)
       when state in ~w(behind blocked unstable draft), do: state

  defp merge_state(_, %{"mergeable" => true}, _), do: "mergeable"
  defp merge_state(_, _, _), do: "unknown"
end
