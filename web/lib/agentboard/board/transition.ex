defmodule Agentboard.Board.Transition do
  @moduledoc "Ownership and lifecycle rules evaluated after the aggregate row lock."
  alias Agentboard.Board.Operations
  @active ~w(in_progress blocked review)

  def attributes(task, action, actor, data, now) do
    if task.status in ~w(done cancelled), do: conflict("Terminal tasks are immutable")

    if data["revision"] && data["revision"] != task.revision,
      do: conflict("Task revision changed; reload before editing")

    permitted =
      task.status == "open" or
        (task.status == "assigned" and actor in [task.assignee_id, task.assigner_id]) or
        live?(task, actor, now)

    changes(task, action, actor, data, now, permitted)
    |> Map.merge(%{revision: task.revision + 1, updated_at: now})
  end

  defp changes(t, "assign", actor, d, _now, permitted) do
    unless t.status in ~w(open assigned) and permitted,
      do: conflict("Only open or permitted pending work can be assigned")

    %{status: "assigned", assignee_id: d["to"], assigner_id: actor}
  end

  defp changes(t, "claim", actor, d, now, _permitted) do
    unless t.status == "open" or (t.status == "assigned" and t.assignee_id == actor),
      do: conflict("Task is not available to claim; renew or explicitly recover expired work")

    %{
      status: "in_progress",
      assignee_id: actor,
      claimed_at: now,
      claim_expires_at: expiry(now, d)
    }
  end

  defp changes(t, "renew", _actor, d, now, permitted) do
    unless t.status in @active and permitted, do: conflict("Only the live owner can renew")
    %{claim_expires_at: expiry(now, d)}
  end

  defp changes(t, "reclaim", actor, d, now, _permitted) do
    unless t.status in @active and expired?(t, now),
      do: conflict("Only an expired active claim can be reclaimed")

    %{
      status: "in_progress",
      assignee_id: actor,
      assigner_id: nil,
      claimed_at: now,
      claim_expires_at: expiry(now, d)
    }
  end

  defp changes(t, "release", actor, d, now, permitted) do
    unless (t.status == "assigned" and t.assignee_id == actor) or
             (t.status in @active and (permitted or (expired?(t, now) and d["expired"] == true))),
           do: conflict("Release requires the assignee/live owner or explicit expired recovery")

    %{status: "open", assignee_id: nil, assigner_id: nil, claimed_at: nil, claim_expires_at: nil}
  end

  defp changes(_t, action, _actor, d, _now, permitted) when action in ~w(edit link) do
    unless permitted, do: conflict("Task edit requires permitted ownership")
    fields = ~w(title description priority repo labels issue_url pr_url)a

    Map.new(fields, &{&1, d[Atom.to_string(&1)]})
    |> Map.take(Enum.filter(fields, &Map.has_key?(d, Atom.to_string(&1))))
  end

  defp changes(t, "handoff", actor, d, now, _permitted) do
    unless live?(t, actor, now), do: conflict("Handoff requires the live owner")

    %{
      status: "assigned",
      assignee_id: d["to"],
      assigner_id: actor,
      claimed_at: nil,
      claim_expires_at: nil
    }
  end

  defp changes(t, "update", _actor, d, _now, permitted) do
    status = d["status"]

    unless permitted or (t.status == "assigned" and status == "cancelled"),
      do: conflict("Task update requires permitted ownership")

    if status do
      allowed =
        case t.status do
          "open" -> ["cancelled"]
          "assigned" -> ["cancelled"]
          "in_progress" -> ~w(blocked review done cancelled)
          "blocked" -> ~w(in_progress review cancelled)
          "review" -> ~w(in_progress blocked done cancelled)
        end

      unless status in allowed, do: conflict("Unsupported status transition")

      if status == "blocked" and not Agentboard.Input.text?(d["note"]),
        do: Operations.reject("invalid_input", "Blocked status requires a reason")

      if status in ~w(done cancelled),
        do: %{status: status, claimed_at: nil, claim_expires_at: nil},
        else: %{status: status}
    else
      unless Agentboard.Input.text?(d["note"]),
        do: Operations.reject("invalid_input", "A note or status is required")

      %{}
    end
  end

  defp live?(t, actor, now),
    do: t.status in @active and t.assignee_id == actor and not expired?(t, now)

  defp expired?(t, now), do: DateTime.compare(t.claim_expires_at, now) != :gt

  defp expiry(now, data) do
    seconds = Map.get(data, "ttl_seconds", 7200)

    if Agentboard.Input.representable_offset?(seconds),
      do: DateTime.add(now, round(seconds * 1_000_000), :microsecond),
      else: Operations.reject("invalid_input", "Invalid task fields or action")
  end

  defp conflict(message), do: Operations.reject("conflict", message)
end

