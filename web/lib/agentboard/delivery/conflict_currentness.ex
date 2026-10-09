defmodule Agentboard.Delivery.ConflictCurrentness do
  @moduledoc "One canonical evaluator and sorted transaction prefix for single and frozen batch consumers."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Agent, Task, Message}
  alias Agentboard.Cooperation.Event

  alias Agentboard.Delivery.{
    BaseMonitor,
    BaseWatch,
    ConflictOrder,
    ConflictPolicy,
    ConflictSource,
    PollState,
    PullRequest,
    RebaseFollowUp
  }

  alias Agentboard.{Availability, Repo}
  require Ash.Query

  # Caller owns the transaction. Lock ALL branch identities before ANY PR/poll,
  # then policy/agent, then sorted repair tasks/orders. Never nest single-source
  # callbacks for batches. Immutable source reads perform no election.
  def lock(descriptors, recipient) do
    sources =
      Enum.map(Enum.uniq(descriptors), fn {kind, id, version} ->
        {kind, id, version, source(kind, id)}
      end)

    orders =
      sources
      |> Enum.map(&elem(&1, 3))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Ash.get!(ConflictOrder, &1.order_id))
      |> Enum.uniq_by(& &1.id)

    prs = orders |> Enum.map(&Ash.get!(PullRequest, &1.pull_request_id)) |> Enum.uniq_by(& &1.id)
    pr_by_id = Map.new(prs, &{&1.id, &1})

    watches =
      orders
      |> Enum.flat_map(fn order ->
        pr = pr_by_id[order.pull_request_id]

        Enum.map(
          Enum.uniq([order.default_ref, order.evaluation_base_ref]),
          &BaseMonitor.id(pr.owner, pr.repo, &1)
        )
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Map.new(fn id ->
        Repo.statement!("SELECT id FROM delivery_base_watches WHERE id=$1 FOR SHARE", [id])
        watch = Ash.get!(BaseWatch, id, not_found_error?: false)
        {id, if(watch, do: watch.head_sha)}
      end)

    Enum.each(Enum.sort_by(prs, & &1.id), fn pr ->
      Repo.statement!("SELECT id FROM delivery_pull_requests WHERE id=$1 FOR SHARE", [pr.id])
    end)

    Enum.each(Enum.sort_by(prs, & &1.id), fn pr ->
      Repo.statement!("SELECT id FROM delivery_poll_states WHERE id=$1 FOR SHARE", [pr.id])
    end)

    if orders != [] do
      Availability.lock_admission()
      Repo.statement!("SELECT id FROM agents WHERE id=$1 FOR SHARE", [recipient])

      orders
      |> Enum.map(& &1.repair_task_id)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&Ops.lock_task/1)

      Enum.each(Enum.sort_by(orders, & &1.id), fn order ->
        Repo.statement!("SELECT id FROM delivery_conflict_orders WHERE id::text=$1 FOR SHARE", [
          order.id
        ])
      end)
    end

    Map.new(sources, fn {kind, id, version, source} ->
      {{kind, to_string(id), version}, evaluate(source, kind, version, recipient, watches)}
    end)
  end

  def source("event", id), do: Ash.get!(ConflictSource, id, not_found_error?: false)

  def source("board_message", id) do
    case Integer.parse(to_string(id)) do
      {number, ""} -> ConflictSource |> Ash.Query.filter(message_id == ^number) |> Ash.read_one!()
      _ -> nil
    end
  end

  def source(_, _), do: nil

  defp evaluate(nil, _, _, _, _), do: %{state: "unsupported"}

  defp evaluate(source, kind, version, recipient, watches) do
    if ConflictPolicy.mode() != "apply" or
         not Application.get_env(:agentboard, :cooperation_enabled, false) do
      %{state: "unsupported"}
    else
      agent = Ash.get!(Agent, recipient, not_found_error?: false)
      order = Ash.get!(ConflictOrder, source.order_id)
      task = Ash.get!(Task, order.repair_task_id)
      pr = Ash.get!(PullRequest, order.pull_request_id)
      poll = Ash.get!(PollState, pr.id)

      follow =
        RebaseFollowUp
        |> Ash.Query.filter(current_order_id == ^order.id and is_nil(resolved_at))
        |> Ash.read_one!()

      event = Ash.get!(Event, source.id)
      expected_version = if kind == "event", do: source.source_key, else: source.message_version
      message = if kind == "board_message", do: Ash.get!(Message, source.message_id)

      selected? =
        (kind == "event" and source.disposition == "worker") or
          (kind == "board_message" and source.disposition in ~w(sent adopted))

      current? =
        selected? and not is_nil(agent) and is_nil(agent.retired_at) and is_binary(recipient) and
          order.state == "open" and is_nil(order.resolved_at) and
          order.revision == source.order_revision and not is_nil(follow) and
          order.recipient_id == recipient and task.assignee_id == recipient and
          task.status not in ~w(done cancelled) and task.pr_url == pr.url and
          event.source_key == source.source_key and event.task_id == task.id and
          event.repo == pr.owner <> "/" <> pr.repo and expected_version == version and
          (is_nil(message) or
             (is_nil(message.read_at) and message.recipient_id == recipient and
                DateTime.to_iso8601(message.created_at) == source.message_version)) and
          poll.lifecycle == "open" and poll.head_sha == order.observed_head_sha and
          poll.default_ref == order.default_ref and
          poll.expected_default_sha == order.default_tip_sha and
          poll.base_ref == order.evaluation_base_ref and
          poll.expected_base_sha == order.evaluation_base_sha and
          watches[BaseMonitor.id(pr.owner, pr.repo, order.default_ref)] == order.default_tip_sha and
          watches[BaseMonitor.id(pr.owner, pr.repo, order.evaluation_base_ref)] ==
            order.evaluation_base_sha

      state = if current?, do: "pending", else: "stale_order"
      %{state: state, order_ref: reference(order)}
    end
  end

  def reference(order) do
    %{
      "kind" => "pr_conflict_order",
      "order_id" => order.id,
      "order_revision" => order.revision,
      "repair_task_id" => order.repair_task_id,
      "pull_request_id" => order.pull_request_id,
      "default_ref" => order.default_ref,
      "default_tip_sha" => order.default_tip_sha,
      "evaluation_base_ref" => order.evaluation_base_ref,
      "evaluation_base_sha" => order.evaluation_base_sha,
      "recipient_id" => order.recipient_id
    }
  end
end
