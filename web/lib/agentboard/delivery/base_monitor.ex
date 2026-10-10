defmodule Agentboard.Delivery.BaseMonitor do
  @moduledoc "Branch I/O outside short database transactions; revision-fenced, restartable PR invalidation."
  alias Agentboard.Board.Operations, as: Ops

  alias Agentboard.Delivery.{
    BaseWatch,
    ConflictPolicy,
    BaseWorker,
    BaseInvalidationWorker,
    Github,
    PollState,
    PullRequest,
    Scheduling
  }

  alias Agentboard.Repo
  require Ash.Query
  @actor %{"agent" => "delivery-observation", "model" => "system", "harness" => "ash"}

  def id(owner, repo, ref),
    do: :crypto.hash(:sha256, Enum.join([owner, repo, ref], ":")) |> Base.encode16(case: :lower)

  # Reads never acquire a branch lock while a PR reservation is held. A named
  # branch's last admitted revision also fences the gap before paged invalidation.
  def expected_sha(pr, ref, fallback) when is_binary(ref) do
    case Ash.get!(BaseWatch, id(pr.owner, pr.repo, ref), not_found_error?: false) do
      %{last_success_at: %DateTime{}, head_sha: sha} -> sha
      _ -> fallback
    end
  end

  def expected_sha(_, _, fallback), do: fallback

  # Capture before provider I/O without taking a branch lock under PollState.
  # GitHub pull.base.sha may lag an idle PR's current branch indefinitely.
  def capture(pr) do
    BaseWatch
    |> Ash.Query.filter(owner == ^pr.owner and repo == ^pr.repo)
    |> Ash.read!()
    |> Map.new(fn watch -> {watch.ref, {watch.revision, watch.head_sha}} end)
  end

  def assert_current!(reservation, %{lifecycle: "open"} = result) do
    {owner, repo} = resolve_scope(reservation)

    watches =
      Map.get(reservation, :base_watches, Map.get(reservation, "base_watches", %{})) || %{}

    refs = observation_refs(result)
    strict? = is_binary(result.payload["default_ref"])

    # Lock all watched identities in the same order before PollState. Default
    # and actual target may differ; neither is acquired under a PR reservation.
    admitted =
      refs
      |> Enum.sort()
      |> Map.new(fn {ref, sha} ->
        key = id(owner, repo, ref)
        Repo.statement!("SELECT id FROM delivery_base_watches WHERE id=$1 FOR SHARE", [key])
        watch = Ash.get!(BaseWatch, key, not_found_error?: false)
        current = if watch, do: {watch.revision, watch.head_sha}
        before = Map.get(watches, ref)
        same? = before == current or (is_nil(before) and current == {0, sha})
        evidence_current? = not strict? or is_nil(watch) or watch.head_sha == sha

        unless same? and evidence_current?,
          do: Ops.reject("base_changed", "Base watch changed during collection")

        {ref, if(watch && watch.last_success_at, do: watch.head_sha, else: sha)}
      end)

    Map.get(admitted, result.payload["base_ref"], result.base_sha)
  end

  def assert_current!(_reservation, result), do: result.base_sha

  defp observation_refs(result) do
    base = result.payload["base_ref"]

    refs =
      if is_binary(base),
        do: %{base => result.payload["evaluation_base_sha"] || result.base_sha},
        else: %{}

    default = result.payload["default_ref"]

    if is_binary(default) and is_binary(result.payload["default_tip_sha"]),
      do: Map.put(refs, default, result.payload["default_tip_sha"]),
      else: refs
  end

  defp resolve_scope(reservation) do
    owner = Map.get(reservation, :owner, Map.get(reservation, "owner"))
    repo = Map.get(reservation, :repo, Map.get(reservation, "repo"))

    if is_binary(owner) and is_binary(repo) do
      {owner, repo}
    else
      pr =
        Ops.fetch!(
          PullRequest,
          Map.get(reservation, :id, Map.get(reservation, "id")),
          "PR not found"
        )

      {pr.owner, pr.repo}
    end
  end

  def enroll(pr, observation) do
    if observation.lifecycle == "open" do
      Ops.transaction(fn ->
        observation_refs(observation)
        |> Enum.sort()
        |> Enum.each(fn {ref, sha} ->
          enroll_branch(pr.owner, pr.repo, ref, sha)
        end)
      end)
    else
      {:ok, :skipped}
    end
  end

  defp enroll_branch(owner, repo, ref, sha) do
    key = id(owner, repo, ref)
    <<lock::signed-64, _::binary>> = :crypto.hash(:sha256, "agentboard-base:" <> key)
    Repo.statement!("SELECT pg_advisory_xact_lock($1)", [lock])

    Ash.get!(BaseWatch, key, not_found_error?: false) ||
      Ops.create(
        BaseWatch,
        :enroll,
        %{id: key, owner: owner, repo: repo, ref: ref, head_sha: sha, next_poll_at: Ops.now()},
        @actor
      )
  end

  def tick do
    if Scheduling.enabled?() do
      Ops.transaction(fn ->
        # Catch the crash gap between a committed PR observation and enrollment.
        %{rows: missing} =
          Repo.statement!(
            "SELECT DISTINCT candidates.owner,candidates.repo,candidates.ref,candidates.sha FROM (SELECT p.owner,p.repo,s.base_ref AS ref,COALESCE(c.payload->>'evaluation_base_sha',s.base_sha) AS sha FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id LEFT JOIN delivery_ci_snapshots c ON c.id=s.snapshot_id WHERE s.enabled AND s.lifecycle='open' UNION ALL SELECT p.owner,p.repo,c.payload->>'default_ref',c.payload->>'default_tip_sha' FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id JOIN delivery_ci_snapshots c ON c.id=s.snapshot_id WHERE $1 AND s.enabled AND s.lifecycle='open') candidates WHERE candidates.ref IS NOT NULL AND candidates.sha IS NOT NULL AND NOT EXISTS (SELECT 1 FROM delivery_base_watches b WHERE b.owner=candidates.owner AND b.repo=candidates.repo AND b.ref=candidates.ref) ORDER BY candidates.owner,candidates.repo,candidates.ref,candidates.sha LIMIT 100",
            [ConflictPolicy.observe_defaults?()]
          )

        Enum.each(missing, fn [owner, repo, ref, sha] -> enroll_branch(owner, repo, ref, sha) end)

        %{rows: due} =
          Repo.statement!(
            "SELECT b.id FROM delivery_base_watches b WHERE b.next_poll_at<=clock_timestamp() AND (b.lease_expires_at IS NULL OR b.lease_expires_at<=clock_timestamp()) AND EXISTS (SELECT 1 FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id WHERE s.enabled AND s.lifecycle='open' AND p.owner=b.owner AND p.repo=b.repo AND (s.base_ref=b.ref OR ($1 AND s.default_ref=b.ref))) ORDER BY b.next_poll_at,b.id LIMIT 10",
            [ConflictPolicy.observe_defaults?()]
          )

        Enum.each(due, fn [key] -> %{"id" => key} |> BaseWorker.new() |> Oban.insert!() end)
        # A discarded pager is recoverable. Replaying earlier pages cannot reset
        # a reservation already bound to this revision's expected base.
        %{rows: unfinished} =
          Repo.statement!(
            "SELECT id,revision FROM delivery_base_watches WHERE invalidated_revision<revision ORDER BY id LIMIT 10",
            []
          )

        Enum.each(unfinished, fn [key, revision] -> enqueue_page(key, revision, "") end)
        %{scheduled: length(due), recovered: length(unfinished)}
      end)
    else
      snooze()
    end
  end

  def check(key) do
    if Scheduling.enabled?() do
      case reserve(key) do
        {:ok, nil} -> {:ok, %{skipped: true}}
        {:ok, branch} -> commit(branch, Github.branch(branch.owner, branch.repo, branch.ref))
        {:error, _, message} -> {:error, message}
      end
    else
      snooze()
    end
  end

  defp reserve(key) do
    Ops.transaction(fn ->
      %{rows: rows} =
        Repo.statement!(
          "SELECT b.id FROM delivery_base_watches b WHERE b.id=$1 AND b.next_poll_at<=clock_timestamp() AND (b.lease_expires_at IS NULL OR b.lease_expires_at<=clock_timestamp()) AND EXISTS (SELECT 1 FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id WHERE s.enabled AND s.lifecycle='open' AND p.owner=b.owner AND p.repo=b.repo AND (s.base_ref=b.ref OR ($2 AND s.default_ref=b.ref))) FOR UPDATE OF b SKIP LOCKED",
          [key, ConflictPolicy.observe_defaults?()]
        )

      if rows != [] do
        b = Ash.get!(BaseWatch, key)

        Ops.update(
          b,
          :reserve,
          %{
            generation: b.generation + 1,
            attempt_id: Ash.UUID.generate(),
            lease_expires_at: DateTime.add(Ops.now(), 120)
          },
          @actor
        )
      end
    end)
  end

  defp commit(reserved, response) do
    result =
      Ops.transaction(fn ->
        if not Scheduling.enabled?(), do: Ops.reject("disabled", "PR observation disabled")

        Repo.statement!("SELECT id FROM delivery_base_watches WHERE id=$1 FOR UPDATE", [
          reserved.id
        ])

        b = Ash.get!(BaseWatch, reserved.id)
        stamp = Ops.now()

        if b.generation != reserved.generation or b.attempt_id != reserved.attempt_id or
             is_nil(b.lease_expires_at) or DateTime.compare(b.lease_expires_at, stamp) != :gt,
           do: Ops.reject("conflict", "Branch response superseded")

        attrs = %{attempt_id: nil, lease_expires_at: nil}

        case response do
          {:ok, sha} ->
            changed? = sha != b.head_sha
            revision = b.revision + if(changed?, do: 1, else: 0)

            Ops.update(
              b,
              :observe,
              Map.merge(attrs, %{
                head_sha: sha,
                revision: revision,
                last_success_at: stamp,
                last_error: nil,
                next_poll_at: DateTime.add(stamp, 60)
              }),
              @actor
            )

            if changed?, do: enqueue_page(b.id, revision, "")
            %{changed: changed?, revision: revision}

          {:error, reason, seconds} ->
            Ops.update(
              b,
              :observe,
              Map.merge(attrs, %{last_error: reason, next_poll_at: DateTime.add(stamp, seconds)}),
              @actor
            )

            %{deferred: reason, retry_after: seconds}
        end
      end)

    case result do
      {:error, "conflict", _} -> {:ok, %{superseded: true}}
      {:error, "disabled", _} -> snooze()
      {:error, _, message} -> {:error, message}
      other -> other
    end
  end

  def invalidate(%{id: key, revision: revision, cursor: cursor}) do
    if Scheduling.enabled?() do
      result =
        Ops.transaction(fn ->
          Repo.statement!("SELECT id FROM delivery_base_watches WHERE id=$1 FOR UPDATE", [key])
          b = Ops.fetch!(BaseWatch, key, "Branch watch missing")

          if b.revision != revision do
            %{superseded: true}
          else
            %{rows: rows} =
              Repo.statement!(
                "SELECT s.id FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id WHERE s.enabled AND s.lifecycle='open' AND p.owner=$1 AND p.repo=$2 AND (s.base_ref=$3 OR ($5 AND s.default_ref=$3)) AND s.id>$4 ORDER BY s.id LIMIT 100 FOR UPDATE OF s",
                [b.owner, b.repo, b.ref, cursor, ConflictPolicy.observe_defaults?()]
              )

            Enum.each(rows, fn [key] -> invalidate_pr(Ash.get!(PollState, key), b) end)

            if length(rows) == 100,
              do: enqueue_page(b.id, revision, List.last(rows) |> hd()),
              else: Ops.update(b, :invalidate, %{invalidated_revision: revision}, @actor)

            %{invalidated: length(rows)}
          end
        end)

      case result do
        {:error, _, message} -> {:error, message}
        other -> other
      end
    else
      snooze()
    end
  end

  defp invalidate_pr(state, watch) do
    target_changed? = state.base_ref == watch.ref and state.expected_base_sha != watch.head_sha

    default_changed? =
      state.default_ref == watch.ref and state.expected_default_sha != watch.head_sha

    if target_changed? or default_changed? do
      Ops.update(
        state,
        :invalidate_base,
        %{
          generation: state.generation + 1,
          expected_base_sha:
            if(target_changed?, do: watch.head_sha, else: state.expected_base_sha),
          expected_default_sha:
            if(default_changed?, do: watch.head_sha, else: state.expected_default_sha),
          last_error: if(target_changed?, do: "base_changed", else: "default_changed"),
          next_poll_at: Ops.now()
        },
        @actor
      )

      Scheduling.enqueue(state.id)
    end
  end

  defp enqueue_page(key, revision, cursor),
    do:
      %{"id" => key, "revision" => revision, "cursor" => cursor}
      |> BaseInvalidationWorker.new()
      |> Oban.insert!()

  defp snooze, do: {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
end
