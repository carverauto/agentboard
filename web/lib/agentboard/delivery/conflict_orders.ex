defmodule Agentboard.Delivery.ConflictOrders do
  @moduledoc "Base-fenced current orders and authoritative selected-source currentness. No native custody grants."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Task
  alias Agentboard.Cooperation.{Event, Runtime}

  alias Agentboard.Delivery.{
    BaseMonitor,
    BaseWatch,
    ConflictOrder,
    ConflictPolicy,
    ConflictSource,
    PullRequest,
    Rebase,
    RebaseFollowUp
  }

  alias Agentboard.{Availability, Input, Repo}
  require Ash.Query
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}

  # Runs in Polling's existing base-before-poll snapshot transaction.
  def observe(snapshot, result, stamp) do
    if Application.get_env(:agentboard, :cooperation_enabled, false) do
      prior = current(snapshot.pull_request_id)

      case ConflictPolicy.observation_state(result) do
        :closed ->
          cancel(prior, snapshot, stamp, "closed_or_merged")

        :clean ->
          # Cancels obsolete instructions, without inventing actual-rebaser evidence.
          clear(prior, snapshot, stamp)

        :dirty ->
          publish(prior, snapshot, result, stamp)

        :unknown ->
          :ok
      end
    end
  end

  defp current(pr) do
    ConflictOrder
    |> Ash.Query.filter(pull_request_id == ^pr and state == "open")
    |> Ash.read_one!()
  end

  defp publish(prior, snapshot, result, stamp) do
    payload = result.payload

    refs = [
      payload["default_ref"],
      payload["default_tip_sha"],
      payload["base_ref"],
      payload["evaluation_base_sha"]
    ]

    if Enum.all?(refs, &is_binary/1) do
      {follow, pr} = follow_up(prior, snapshot, result, stamp)
      # Lock the repair, never the original source task. Admission precedes repair/order.
      Availability.lock_admission()
      Ops.lock_task(follow.repair_task_id)
      task = Ash.get!(Task, follow.repair_task_id)

      same? =
        not is_nil(prior) and prior.default_ref == payload["default_ref"] and
          prior.default_tip_sha == payload["default_tip_sha"] and
          prior.evaluation_base_ref == payload["base_ref"] and
          prior.evaluation_base_sha == payload["evaluation_base_sha"] and
          prior.recipient_id == task.assignee_id

      if same? do
        Ops.update(
          prior,
          :change,
          %{observed_head_sha: result.head_sha, snapshot_id: snapshot.id, updated_at: stamp},
          @actor
        )
      else
        if prior, do: cancel(prior, snapshot, stamp, "new_evidence", "superseded")
        id = Ash.UUID.generate()

        order =
          Ops.create(
            ConflictOrder,
            :record,
            Map.merge(episode(prior, id, result.head_sha, stamp), %{
              id: id,
              pull_request_id: pr.id,
              default_ref: payload["default_ref"],
              default_tip_sha: payload["default_tip_sha"],
              evaluation_base_ref: payload["base_ref"],
              evaluation_base_sha: payload["evaluation_base_sha"],
              observed_head_sha: result.head_sha,
              snapshot_id: snapshot.id,
              repair_task_id: task.id,
              author_id: follow.responsible_id,
              recipient_id: task.assignee_id,
              state: "open",
              selection_reason: assignment_reason(task, follow),
              created_at: stamp,
              updated_at: stamp
            }),
            @actor
          )

        Ops.update(follow, :set_order, %{current_order_id: order.id}, @actor)
        capture(order, pr)
        Agentboard.Delivery.ConflictDisposition.enqueue(order.id)
      end
    end
  end

  defp assignment_reason(%{assignee_id: nil}, _follow), do: "author_ineligible"

  defp assignment_reason(task, follow) do
    if task.assignee_id == follow.responsible_id,
      do: "author_first",
      else: "retained_repair_assignment"
  end

  defp episode(nil, id, head, stamp) do
    %{
      episode_id: id,
      trigger_head_sha: head,
      revision: 1,
      episode_started_at: stamp,
      deadline_at: DateTime.add(stamp, ConflictPolicy.deadline_seconds())
    }
  end

  defp episode(prior, _id, _head, _stamp) do
    prior
    |> Map.take([:episode_id, :trigger_head_sha, :episode_started_at, :deadline_at])
    |> Map.put(:revision, prior.revision + 1)
  end

  defp follow_up(nil, snapshot, result, stamp) do
    prior =
      RebaseFollowUp
      |> Ash.Query.filter(
        pull_request_id == ^snapshot.pull_request_id and
          head_sha == ^result.head_sha
      )
      |> Ash.read_one!()

    if prior do
      task = Ash.get!(Task, prior.repair_task_id)

      if task.status in ~w(done cancelled),
        do: Ops.reject("unsupported", "Terminal same-head repair requires episode reconciliation")

      follow =
        Ops.update(prior, :resolve, %{resolved_at: nil, resolution_snapshot_id: nil}, @actor)

      {follow, Ash.get!(PullRequest, snapshot.pull_request_id)}
    else
      {follow, pr, _task} = Rebase.create_follow_up(snapshot, result, stamp, routing: true)
      {follow, pr}
    end
  end

  defp follow_up(order, _snapshot, _result, _stamp) do
    follow = RebaseFollowUp |> Ash.Query.filter(current_order_id == ^order.id) |> Ash.read_one!()
    {follow, Ash.get!(PullRequest, order.pull_request_id)}
  end

  defp capture(order, pr) do
    key = "conflict-order:#{order.id}:#{order.revision}"

    event =
      Runtime.capture(
        %{
          source_key: key,
          kind: "pr_conflict",
          repo: pr.owner <> "/" <> pr.repo,
          task_id: order.repair_task_id,
          summary:
            "#{pr.url} conflicts at head #{order.observed_head_sha}, " <>
              "default #{order.default_ref}@#{order.default_tip_sha}, target #{order.evaluation_base_ref}@#{order.evaluation_base_sha}; " <>
              "repair #{order.repair_task_id} by #{DateTime.to_iso8601(order.deadline_at)}. Conflicting files: unknown.",
          source_url: pr.url,
          priority: 1
        },
        recipient: order.recipient_id || "captain"
      )

    {mode, selected} =
      Runtime.fallback(event, [order.recipient_id], @actor,
        recipient: order.recipient_id || "captain",
        capture_notice?: false
      )

    message = if mode in [:sent, :adopted], do: selected

    Ops.create(
      ConflictSource,
      :record,
      %{
        id: event.id,
        order_id: order.id,
        order_revision: order.revision,
        source_key: key,
        message_id: if(message, do: message.id),
        message_version: if(message, do: DateTime.to_iso8601(message.created_at)),
        disposition: Atom.to_string(mode),
        created_at: Ops.now()
      },
      @actor
    )

    if message do
      # The sole election and immutable relation must commit with the typed
      # occurrence. Failure rolls back every source effect; collection retries.
      Agentboard.Mattermost.MessageNotice.capture(message, @actor, message.created_at)

      if order.recipient_id == message.recipient_id do
        Agentboard.WakeIntents.capture_message(message, @actor, %{
          "repo" => pr.owner <> "/" <> pr.repo,
          "order_ref" => Agentboard.Delivery.ConflictCurrentness.reference(order)
        })
      else
        # Unassigned repairs notify the captain for triage. This occurrence
        # conveys no assigned-order or branch-write authority.
        Agentboard.WakeIntents.capture_message(message, @actor)
      end
    end
  end

  defp clear(nil, _snapshot, _stamp), do: :ok

  defp clear(order, snapshot, stamp) do
    if snapshot.head_sha == order.trigger_head_sha do
      cancel(order, snapshot, stamp, "unchanged_head_clean", "cleared_without_repair")
    else
      cancel(order, snapshot, stamp, "mergeable_head_rebaser_unverified")
    end
  end

  defp cancel(nil, _snapshot, _stamp, _reason, _state), do: :ok

  defp cancel(order, snapshot, stamp, reason, state) do
    Ops.lock_task(order.repair_task_id)

    if state != "superseded" do
      follow =
        RebaseFollowUp |> Ash.Query.filter(current_order_id == ^order.id) |> Ash.read_one!()

      if follow,
        do:
          Ops.update(
            follow,
            :resolve,
            %{resolved_at: stamp, resolution_snapshot_id: snapshot.id},
            @actor
          )
    end

    retire_authority(order, stamp)

    Ops.update(
      order,
      :change,
      %{
        state: state,
        resolved_at: stamp,
        resolution_snapshot_id: snapshot.id,
        selection_reason: reason,
        updated_at: stamp
      },
      @actor
    )
  end

  defp retire_authority(order, stamp) do
    Agentboard.Delivery.PublicationGrant
    |> Ash.Query.filter(order_id == ^order.id and state in ["pending", "admitted"])
    |> Ash.read!()
    |> Enum.each(&Ops.update(&1, :change, %{state: "revoked", updated_at: stamp}, @actor))

    if order.escalation_decision_id do
      request = Ash.get!(Agentboard.Decisions.Request, order.escalation_decision_id)

      if request.status in ~w(open answered),
        do:
          Ops.update(
            request,
            :change,
            %{
              status: "superseded",
              closed_by: @actor["agent"],
              close_reason: "conflict_order_retired",
              closed_at: stamp,
              updated_at: stamp
            },
            @actor
          )
    end
  end

  defp cancel(order, snapshot, stamp, reason),
    do: cancel(order, snapshot, stamp, reason, "cancelled")

  # Enrollment holds a worker lock. Read the immutable selected source only;
  # do not re-elect or acquire branch/order/source locks beneath the worker.
  # Inbox selection already owns the effect, so it never becomes a worker frame.
  def bootstrap(follow, subscription) do
    source =
      ConflictSource |> Ash.Query.filter(order_id == ^follow.current_order_id) |> Ash.read_one!()

    if source && source.disposition == "worker" do
      event = Ash.get!(Event, source.id)

      if event.repo in subscription.repos do
        Runtime.ensure_delivery(event, subscription.id, @actor)
      end
    end
  end

  # Read-only API projection. This response is not a grant and cannot fence a
  # later dispatch. In-process consumers use with_current_source/5 at effect admission.
  def resolve_source(actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         true <-
           is_map(data) and Enum.sort(Map.keys(data)) == ~w(source_id source_kind source_version),
         true <- valid_identity?(data["source_kind"], data["source_id"]),
         true <- is_binary(data["source_version"]) and byte_size(data["source_version"]) in 1..255,
         {:ok, _agent} <- Ops.registered_agent(actor["agent"], actor["harness"]) do
      with_current_source(
        data["source_kind"],
        data["source_id"],
        data["source_version"],
        actor["agent"],
        fn ref -> %{"order_ref" => ref, "native_publication" => "unsupported"} end
      )
    else
      false -> {:error, "invalid_input", "Exact selected-source kind, ID and version required"}
      error -> error
    end
  end

  defp valid_identity?("event", id), do: match?({:ok, _}, Ecto.UUID.cast(id))
  defp valid_identity?("board_message", id), do: is_integer(id) and id > 0
  defp valid_identity?(_, _), do: false

  # A consumer must call this BEFORE taking any worker/source/intent lock.
  # The callback executes inside the SAME transaction as the base/order fence;
  # returning a boolean for a later unrelated transaction would reopen the race.
  # Event version is source_key; inbox version is exact Message.created_at RFC3339.
  def with_current_source(kind, id, version, recipient, consumer) when is_function(consumer, 1) do
    Ops.transaction(fn ->
      unless Input.slug?(recipient),
        do: Ops.reject("invalid_input", "Registered recipient ID required")

      result =
        Agentboard.Delivery.ConflictCurrentness.lock([{kind, id, version}], recipient)[
          {kind, to_string(id), version}
        ]

      if result.state != "pending",
        do: Ops.reject(result.state, "Conflict source is not the current assigned order")

      consumer.(result.order_ref)
    end)
  end

  # Shared prefix used by selected-source admission and the deadline consumer.
  # Both acquire canonical default/target -> PR -> poll before policy/candidate/task.
  def lock_evidence(order, pr) do
    watches = lock_bases(pr, order)
    Repo.statement!("SELECT id FROM delivery_pull_requests WHERE id=$1 FOR SHARE", [pr.id])
    Repo.statement!("SELECT id FROM delivery_poll_states WHERE id=$1 FOR SHARE", [pr.id])
    watches
  end

  # Called only by the base-fenced system routing transaction after candidate
  # admission and repair/order revision recheck. This never impersonates an owner.
  def reassign(order, task, pr, candidate, reason, stamp) do
    grant = Availability.admit(task, "handoff", @actor, %{"to" => candidate.agent_id})

    changed =
      Ops.update(
        task,
        :handoff,
        Map.merge(
          %{
            status: "assigned",
            assignee_id: candidate.agent_id,
            assigner_id: @actor["agent"],
            claimed_at: nil,
            claim_expires_at: nil,
            revision: task.revision + 1,
            updated_at: stamp
          },
          grant
        ),
        @actor,
        task.revision
      )

    Ops.project_event(
      task.id,
      @actor,
      "repair_routed",
      reason,
      task.revision,
      changed.revision,
      %{
        before: Ops.public(task),
        after: Ops.public(changed),
        order_id: order.id,
        order_revision: order.revision,
        eligibility: candidate,
        native_custody: "unsupported"
      },
      stamp
    )

    cancel(
      order,
      Ash.get!(Agentboard.Delivery.CISnapshot, order.snapshot_id),
      stamp,
      reason,
      "superseded"
    )

    follow = RebaseFollowUp |> Ash.Query.filter(current_order_id == ^order.id) |> Ash.read_one!()

    fields =
      Map.take(order, [
        :pull_request_id,
        :default_ref,
        :default_tip_sha,
        :evaluation_base_ref,
        :evaluation_base_sha,
        :observed_head_sha,
        :snapshot_id,
        :repair_task_id,
        :author_id
      ])

    id = Ash.UUID.generate()

    replacement =
      Ops.create(
        ConflictOrder,
        :record,
        fields
        |> Map.merge(episode(order, id, order.observed_head_sha, stamp))
        |> Map.merge(%{
          id: id,
          recipient_id: candidate.agent_id,
          state: "open",
          selection_reason: reason,
          created_at: stamp,
          updated_at: stamp
        }),
        @actor
      )

    Ops.update(follow, :set_order, %{current_order_id: replacement.id}, @actor)
    capture(replacement, pr)
    replacement
  end

  defp lock_bases(pr, order) do
    [order.default_ref, order.evaluation_base_ref]
    |> Enum.uniq()
    |> Enum.sort()
    |> Map.new(fn ref ->
      key = BaseMonitor.id(pr.owner, pr.repo, ref)
      Repo.statement!("SELECT id FROM delivery_base_watches WHERE id=$1 FOR SHARE", [key])
      watch = Ash.get!(BaseWatch, key, not_found_error?: false)
      {ref, if(watch, do: watch.head_sha)}
    end)
  end
end
