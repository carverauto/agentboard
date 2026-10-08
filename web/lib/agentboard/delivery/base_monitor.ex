defmodule Agentboard.Delivery.BaseMonitor do
  @moduledoc "Branch I/O outside short database transactions; revision-fenced, restartable PR invalidation."
  alias Agentboard.Board.Operations, as: Ops

  alias Agentboard.Delivery.{
    BaseWatch,
    BaseWorker,
    BaseInvalidationWorker,
    Github,
    PollState,
    Scheduling
  }

  alias Agentboard.Repo
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

  def assert_current!(pr, state, result) do
    if result.lifecycle != "open", do: :ok, else: fence!(pr, state, result)
  end

  defp fence!(pr, state, result) do
    ref = result.payload["base_ref"]

    if is_binary(ref) do
      fallback = if state.base_ref == ref, do: state.expected_base_sha
      expected = expected_sha(pr, ref, fallback)

      if expected && expected != result.base_sha,
        do: Ops.reject("conflict", "Base revision changed during collection")
    end
  end

  def enroll(pr, observation) do
    ref = observation.payload["base_ref"]

    if observation.lifecycle == "open" and is_binary(ref) do
      Ops.transaction(fn -> enroll_branch(pr.owner, pr.repo, ref, observation.base_sha) end)
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
            "SELECT DISTINCT p.owner,p.repo,s.base_ref,s.base_sha FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id WHERE s.enabled AND s.lifecycle='open' AND s.base_ref IS NOT NULL AND s.base_sha IS NOT NULL AND NOT EXISTS (SELECT 1 FROM delivery_base_watches b WHERE b.owner=p.owner AND b.repo=p.repo AND b.ref=s.base_ref) ORDER BY p.owner,p.repo,s.base_ref,s.base_sha LIMIT 100",
            []
          )

        Enum.each(missing, fn [owner, repo, ref, sha] -> enroll_branch(owner, repo, ref, sha) end)

        %{rows: due} =
          Repo.statement!(
            "SELECT b.id FROM delivery_base_watches b WHERE b.next_poll_at<=clock_timestamp() AND (b.lease_expires_at IS NULL OR b.lease_expires_at<=clock_timestamp()) AND EXISTS (SELECT 1 FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id WHERE s.enabled AND s.lifecycle='open' AND p.owner=b.owner AND p.repo=b.repo AND s.base_ref=b.ref) ORDER BY b.next_poll_at,b.id LIMIT 10",
            []
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
          "SELECT b.id FROM delivery_base_watches b WHERE b.id=$1 AND b.next_poll_at<=clock_timestamp() AND (b.lease_expires_at IS NULL OR b.lease_expires_at<=clock_timestamp()) AND EXISTS (SELECT 1 FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id WHERE s.enabled AND s.lifecycle='open' AND p.owner=b.owner AND p.repo=b.repo AND s.base_ref=b.ref) FOR UPDATE OF b SKIP LOCKED",
          [key]
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
                "SELECT s.id FROM delivery_poll_states s JOIN delivery_pull_requests p ON p.id=s.id WHERE s.enabled AND s.lifecycle='open' AND p.owner=$1 AND p.repo=$2 AND s.base_ref=$3 AND s.id>$4 ORDER BY s.id LIMIT 100 FOR UPDATE OF s",
                [b.owner, b.repo, b.ref, cursor]
              )

            Enum.each(rows, fn [key] ->
              s = Ash.get!(PollState, key)

              if s.expected_base_sha != b.head_sha do
                Ops.update(
                  s,
                  :invalidate_base,
                  %{
                    generation: s.generation + 1,
                    expected_base_sha: b.head_sha,
                    next_poll_at: Ops.now()
                  },
                  @actor
                )

                Scheduling.enqueue(key)
              end
            end)

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

  defp enqueue_page(key, revision, cursor),
    do:
      %{"id" => key, "revision" => revision, "cursor" => cursor}
      |> BaseInvalidationWorker.new()
      |> Oban.insert!()

  defp snooze, do: {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
end
