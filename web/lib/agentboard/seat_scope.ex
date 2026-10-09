defmodule Agentboard.SeatScope do
  @moduledoc "Durable captain scope and shared task matching; no scheduler or role inference."
  alias Agentboard.{Availability, Input, Repo}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Agent
  alias Agentboard.SeatScope.Policy
  require Ash.Query

  # Scope writers share availability's exclusive lock. All new-work admission
  # holds the corresponding shared lock through commit, including absent rows.
  def set(id, actor, data) do
    with {:ok, actor} <- Input.actor(actor),
         true <- actor[:availability_admin] == true,
         true <- Input.slug?(id),
         {:ok, attrs} <- validate(data) do
      Ops.transaction(fn ->
        Availability.lock_policy()
        Ops.identity!(actor)
        Ops.fetch!(Agent, id, "Agent must be registered", "invalid_input")
        prior = get(id)
        revision = if prior, do: prior.revision, else: 0

        if revision != data["revision"],
          do: Ops.reject("conflict", "Seat scope revision changed; reload")

        attrs =
          Map.merge(attrs, %{
            revision: revision + 1,
            changed_by: actor["agent"],
            updated_at: Ops.now()
          })

        row =
          if prior,
            do: Ops.update(prior, :set_scope, attrs, actor, revision),
            else: Ops.create(Policy, :create_scope, Map.put(attrs, :agent_id, id), actor)

        Repo.statement!("SELECT pg_notify('ab_agents', 'seat-scope')", [])
        %{"scope" => public(row, id)}
      end)
    else
      false -> {:error, "forbidden", "Verified captain capability and valid agent ID required"}
      error -> error
    end
  end

  def show(id) do
    if Input.slug?(id) do
      Ops.transaction(fn ->
        Ops.fetch!(Agent, id, "Agent not found")
        %{"scope" => public(get(id), id)}
      end)
    else
      {:error, "invalid_input", "Invalid agent ID"}
    end
  end

  def get(id), do: Ash.get!(Policy, id, not_found_error?: false)

  def for_agents(ids) do
    Policy
    |> Ash.Query.filter(agent_id in ^ids)
    |> Ash.read!()
    |> Map.new(&{&1.agent_id, public(&1, &1.agent_id)})
  end

  def public(nil, id),
    do: %{
      "agent_id" => id,
      "state" => "unmanaged",
      "revision" => 0,
      "allowed_repos" => [],
      "required_labels" => [],
      "allowed_labels" => [],
      "changed_by" => nil,
      "updated_at" => nil
    }

  def public(row, _id), do: row |> Ops.public() |> Map.put("state", "managed")

  # No row retains legacy manual compatibility. A future scheduler MUST use
  # managed_matches?/2 as only a scope precondition. Neither function proves
  # automatic eligibility: role, enrollment, readiness and host gates are deferred.
  def matches?(nil, _task), do: true
  def matches?(%{"state" => "unmanaged"}, _task), do: true

  def matches?(scope, task) do
    repo = canonical_repo(field(task, :repo))
    labels = field(task, :labels) || []
    required = field(scope, :required_labels) || []
    allowed = field(scope, :allowed_labels) || []

    not is_nil(repo) and repo in (field(scope, :allowed_repos) || []) and
      Enum.all?(required, &(&1 in labels)) and
      (allowed == [] or Enum.any?(allowed, &(&1 in labels)))
  end

  def managed_matches?(nil, _task), do: false
  def managed_matches?(%{"state" => "unmanaged"}, _task), do: false
  def managed_matches?(scope, task), do: matches?(scope, task)

  def admit!(task, agent_id) do
    unless matches?(get(agent_id), task),
      do: Ops.reject("conflict", "Task repository or labels are outside the recipient seat scope")

    :ok
  end

  def guard_edit!(task, attrs) do
    if task.assignee_id &&
         Enum.any?(
           [:repo, :labels],
           &(Map.has_key?(attrs, &1) and Map.get(attrs, &1) != Map.get(task, &1))
         ) do
      admit!(Map.merge(task, attrs), task.assignee_id)
    end

    :ok
  end

  def admit_repos!(agent_id, repos) do
    case get(agent_id) do
      nil ->
        :ok

      scope ->
        unless Enum.all?(repos, &(canonical_repo(&1) in scope.allowed_repos)),
          do: Ops.reject("conflict", "Enrollment repositories exceed the managed seat scope")

        :ok
    end
  end

  def canonical_repo(value) when is_binary(value) do
    if byte_size(value) <= 256 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9_.-]+\z/, value) and
         List.last(String.split(value, "/")) not in [".", ".."],
       do: String.downcase(value),
       else: nil
  end

  def canonical_repo(_), do: nil

  def validate(data) when is_map(data) do
    repos = data["allowed_repos"]

    valid? =
      Enum.sort(Map.keys(data)) ==
        Enum.sort(~w(allowed_repos required_labels allowed_labels revision)) and
        is_integer(data["revision"]) and data["revision"] >= 0 and
        is_list(repos) and length(repos) in 1..100 and
        Enum.all?(repos, &(canonical_repo(&1) != nil)) and
        labels?(data["required_labels"]) and labels?(data["allowed_labels"])

    if valid?,
      do:
        {:ok,
         %{
           allowed_repos: repos |> Enum.map(&canonical_repo/1) |> Enum.uniq(),
           required_labels: Enum.uniq(data["required_labels"]),
           allowed_labels: Enum.uniq(data["allowed_labels"])
         }},
      else: invalid()
  end

  def validate(_), do: invalid()

  defp labels?(value),
    do:
      is_list(value) and length(value) <= 100 and
        Enum.all?(
          value,
          &(Input.text?(&1) and byte_size(&1) <= 256 and not String.contains?(&1, "*") and
              not Regex.match?(~r/[\x00-\x1f\x7f]/, &1))
        )

  defp invalid,
    do:
      {:error, "invalid_input",
       "Full scope replacement requires nonempty explicit owner/repo allowed_repos, label arrays and nonnegative revision; wildcards and unknown fields are forbidden"}

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
