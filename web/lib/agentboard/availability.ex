defmodule Agentboard.Availability do
  @moduledoc "Shared new-work admission with DB-clock policy resolution and attributed Ash expiry."
  alias Agentboard.{Input, Repo}
  alias Agentboard.Availability.Policy
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Agent, Task}
  require Ash.Query
  @lock 48_713_081
  @system %{
    "agent" => "availability-expiry",
    "model" => "system",
    "harness" => "ash",
    :availability_admin => true
  }

  # Shared readers do not serialize unrelated tasks. Policy writes take the
  # exclusive lock before writing; admission holds its shared lock to commit.
  def lock_admission, do: Repo.statement!("SELECT pg_advisory_xact_lock_shared($1)", [@lock])
  defp lock_policy, do: Repo.statement!("SELECT pg_advisory_xact_lock($1)", [@lock])

  def effective(agent) do
    %{rows: [[value]]} =
      Repo.statement!("SELECT board_agent_availability($1,$2,$3)", [
        agent.id,
        agent.harness,
        agent.model
      ])

    value
  end

  # Register/heartbeat update the model under FOR UPDATE. Hold this compatible
  # row lock through admission commit so a concurrent model change cannot race it.
  def admission_agent(id) do
    Repo.statement!("SELECT id FROM agents WHERE id=$1 FOR SHARE", [id])
    Ops.fetch!(Agent, id, "Agent must be registered", "invalid_input")
  end

  def active?(agent), do: effective(agent)["state"] == "active"

  def admit(task, action, actor, data) when action in ~w(assign handoff claim reclaim) do
    target = if action in ~w(assign handoff), do: data["to"], else: actor["agent"]
    agent = admission_agent(target)

    if agent.retired_at != nil,
      do: Ops.reject("conflict", "Retired identity cannot receive new work")

    state = effective(agent)["state"]

    named? =
      action == "claim" and task.status == "assigned" and task.assignee_id == target and
        task.assignment_authorized

    authorized? = actor[:availability_admin] == true

    unless state == "active" or
             (state == "reserved" and (named? or (action in ~w(assign handoff) and authorized?))),
           do: Ops.reject("conflict", "Agent availability #{state} refuses new #{action}")

    cond do
      action in ~w(assign handoff) -> %{assignment_authorized: authorized?}
      action == "reclaim" -> %{assignment_authorized: false}
      true -> %{}
    end
  end

  def admit(_task, action, _actor, _data) when action in ~w(release),
    do: %{assignment_authorized: false}

  def admit(_, _, _, _), do: %{}

  def set(actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         true <- actor[:availability_admin] == true,
         {:ok, attrs} <- validate(data) do
      Ops.transaction(fn ->
        lock_policy()
        Ops.identity!(actor)

        if attrs.agent_id,
          do: Ops.fetch!(Agent, attrs.agent_id, "Agent must be registered", "invalid_input")

        id = policy_id(attrs)
        prior = Ash.get!(Policy, id, not_found_error?: false)

        if data["revision"] && (is_nil(prior) or prior.revision != data["revision"]),
          do: Ops.reject("conflict", "Availability revision changed; reload")

        stamp = Ops.now()

        if attrs.until && DateTime.compare(attrs.until, stamp) != :gt,
          do: Ops.reject("invalid_input", "Availability until must be in the future")

        attrs =
          Map.merge(attrs, %{
            id: id,
            revision: if(prior, do: prior.revision + 1, else: 1),
            changed_by: actor["agent"],
            updated_at: stamp
          })

        row =
          if prior,
            do:
              Ops.update(
                prior,
                :set_policy,
                Map.drop(attrs, [:id, :agent_id, :harness, :model_pattern]),
                actor
              ),
            else: Ops.create(Policy, :create_policy, attrs, actor)

        Repo.statement!("SELECT pg_notify('ab_agents', 'availability')", [])
        %{"policy" => Ops.public(row)}
      end)
    else
      false -> {:error, "forbidden", "Verified captain capability required"}
      error -> error
    end
  end

  def history(agent) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT jsonb_build_object('action',v.version_action_name,'changes',v.changes,
          'provenance',v.provenance,'created_at',v.version_inserted_at,'policy_id',p.id)
        FROM availability_policies_versions v JOIN availability_policies p ON p.id=v.version_source_id
        WHERE p.agent_id=$1 OR (p.agent_id IS NULL AND (p.harness IS NULL OR p.harness=$2)
          AND (p.model_pattern IS NULL OR p.model_pattern=$3 OR
            (right(p.model_pattern,1)='*' AND left($3,length(p.model_pattern)-1)=left(p.model_pattern,length(p.model_pattern)-1))))
        ORDER BY v.version_inserted_at DESC,v.id DESC LIMIT 101
        """,
        [agent.id, agent.harness, agent.model]
      )

    %{
      "availability_history" => rows |> Enum.take(100) |> Enum.map(&hd/1),
      "availability_history_more" => length(rows) > 100
    }
  end

  def list do
    with {:ok, _} <- expire_due() do
      {:ok,
       %{
         "policies" =>
           Policy |> Ash.Query.sort(id: :asc) |> Ash.read!() |> Enum.map(&Ops.public/1)
       }}
    end
  end

  def expire_due do
    # Avoid an exclusive lock on the common no-expiry path. Under the lock,
    # reselect due records so concurrent readers produce exactly one audit.
    %{rows: [[due]]} =
      Repo.statement!(
        "SELECT EXISTS(SELECT 1 FROM availability_policies WHERE state='out_of_service' AND \"until\" <= clock_timestamp())",
        []
      )

    if due do
      Ops.transaction(fn ->
        lock_policy()
        stamp = Ops.now()

        rows =
          Policy
          |> Ash.Query.filter(state == "out_of_service" and until <= ^stamp)
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.limit(100)
          |> Ash.read!()

        Enum.each(rows, fn row ->
          Ops.update(
            row,
            :expire,
            %{
              state: "active",
              until: nil,
              revision: row.revision + 1,
              changed_by: @system["agent"],
              updated_at: stamp
            },
            @system
          )
        end)

        if rows != [],
          do: Repo.statement!("SELECT pg_notify('ab_agents', 'availability-expiry')", [])

        %{"expired" => length(rows)}
      end)
    else
      {:ok, %{"expired" => 0}}
    end
  end

  def broadcast(actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         true <- actor[:availability_admin] == true,
         :ok <- validate_broadcast(data) do
      Ops.transaction(fn ->
        lock_admission()
        Ops.identity!(actor)
        Ops.fetch!(Task, data["task"], "Task must exist")

        query =
          Agent
          |> Ash.Query.filter(availability_state == "active")
          |> Ash.Query.filter(is_nil(retired_at))
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.limit(1001)

        query =
          if data["harness"],
            do: Ash.Query.filter(query, harness == ^data["harness"]),
            else: query

        agents = Ash.read!(query)

        if length(agents) > 1000,
          do:
            Ops.reject(
              "invalid_input",
              "Limit broadcast to a harness with at most 1000 eligible agents"
            )

        ids =
          Enum.map(agents, fn agent ->
            # Real message creation retains message/chat intent in the same transaction.
            Ops.send_message(
              actor,
              Map.merge(data, %{"to" => agent.id, "kind" => "task_order"}),
              Ops.now()
            ).id
          end)

        %{"message_ids" => ids, "recipient_ids" => Enum.map(agents, & &1.id)}
      end)
    else
      false -> {:error, "forbidden", "Captain capability and explicit task/body required"}
      error -> error
    end
  end

  defp validate_broadcast(data) when is_map(data) do
    valid? =
      Input.text?(data["body"]) and byte_size(data["body"]) <= 16_384 and
        Input.slug?(data["task"]) and
        (is_nil(data["harness"]) or
           (Input.text?(data["harness"]) and byte_size(data["harness"]) <= 128)) and
        Enum.all?(Map.keys(data), &(&1 in ~w(body task harness)))

    if valid?,
      do: :ok,
      else:
        {:error, "invalid_input",
         "Valid task, body up to 16384 bytes and optional harness required"}
  end

  defp validate_broadcast(_), do: {:error, "invalid_input", "Broadcast must be an object"}

  defp validate(data) when is_map(data) do
    agent = data["agent_id"]
    harness = data["harness"]
    pattern = data["model_pattern"]

    selector? =
      (Input.slug?(agent) and is_nil(harness) and is_nil(pattern)) or
        (is_nil(agent) and (Input.text?(harness) or Input.text?(pattern)))

    valid? =
      selector? and data["state"] in ~w(active reserved out_of_service) and
        (is_nil(harness) or (Input.text?(harness) and byte_size(harness) <= 128)) and
        (is_nil(pattern) or
           (Input.text?(pattern) and byte_size(pattern) <= 256 and
              Regex.match?(~r/^[^*]+\*?$/, pattern))) and
        (is_nil(data["reason"]) or
           (Input.text?(data["reason"]) and byte_size(data["reason"]) <= 4096)) and
        (data["state"] == "active" or Input.text?(data["reason"])) and
        (is_nil(data["revision"]) or (is_integer(data["revision"]) and data["revision"] > 0)) and
        Enum.all?(
          Map.keys(data),
          &(&1 in ~w(agent_id harness model_pattern state reason until revision))
        )

    valid? = valid? and (is_nil(data["until"]) or data["state"] == "out_of_service")
    until_result = if is_nil(data["until"]), do: {:ok, nil}, else: parse_until(data["until"])

    case {valid?, until_result} do
      {true, {:ok, until}} ->
        {:ok,
         %{
           agent_id: agent,
           harness: harness,
           model_pattern: pattern,
           state: data["state"],
           reason: data["reason"],
           until: until
         }}

      _ ->
        {:error, "invalid_input",
         "Explicit valid selector, state, reason and optional out_of_service RFC3339 until required"}
    end
  end

  defp validate(_), do: {:error, "invalid_input", "Availability policy must be an object"}

  defp parse_until(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, stamp, _} -> {:ok, stamp}
      _ -> :error
    end
  end

  defp parse_until(_), do: :error

  defp policy_id(attrs),
    do:
      :crypto.hash(:sha256, Jason.encode!([attrs.agent_id, attrs.harness, attrs.model_pattern]))
      |> Base.encode16(case: :lower)
end
