defmodule Agentboard.CoordinatorTriage do
  @moduledoc "Shadow-only coordinator inbox classification. No routing or acknowledgment authority."
  alias Agentboard.{Input, Repo}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Agent, Message}
  alias Agentboard.CoordinatorTriage.{Configuration, Disposition, Metadata, Record}
  require Ash.Query

  @lock 1_863_001
  @states ~w(recorded blocked escalation_pending unresolved)
  def states, do: @states

  def configuration do
    Ops.transaction(fn -> %{"configuration" => configuration_public(config())} end)
  end

  def configure(actor, data) do
    with true <- actor[:triage_admin] == true,
         true <- is_map(data),
         true <- Enum.sort(Map.keys(data)) == ~w(coordinator_id mode revision),
         true <- data["mode"] in ~w(off shadow),
         true <- is_integer(data["revision"]) and data["revision"] >= 0,
         true <-
           Input.slug?(data["coordinator_id"]) or
             (data["mode"] == "off" and is_nil(data["coordinator_id"])) do
      Ops.transaction(fn ->
        Repo.statement!("SELECT pg_advisory_xact_lock($1)", [@lock])

        if data["coordinator_id"] do
          agent =
            Ops.fetch!(
              Agent,
              data["coordinator_id"],
              "Coordinator must be registered",
              "invalid_input"
            )

          if agent.retired_at, do: Ops.reject("conflict", "Coordinator must not be retired")
        end

        prior = config()
        revision = if prior, do: prior.revision, else: 0

        if revision != data["revision"],
          do: Ops.reject("conflict", "Triage configuration revision changed; reload")

        unless Ash.get!(Agent, actor["agent"], not_found_error?: false) do
          Ops.create(
            Agent,
            :register_new,
            %{
              id: actor["agent"],
              name: "Captain",
              capabilities: [],
              metadata: %{},
              kind: "human",
              model: actor["model"],
              harness: actor["harness"],
              created_at: Ops.now(),
              updated_at: Ops.now()
            },
            actor
          )
        end

        Ops.identity!(actor)

        attrs = %{
          mode: data["mode"],
          coordinator_id: data["coordinator_id"],
          revision: revision + 1,
          changed_by: actor["agent"],
          updated_at: Ops.now()
        }

        row =
          if prior,
            do: Ops.update(prior, :replace, attrs, actor, revision),
            else: Ops.create(Configuration, :record, Map.put(attrs, :id, "coordinator"), actor)

        %{"configuration" => configuration_public(row)}
      end)
    else
      false ->
        if actor[:triage_admin] == true,
          do:
            {:error, "invalid_input",
             "Exact mode, coordinator_id and nonnegative revision required; only off/shadow are supported"},
          else: {:error, "forbidden", "Verified captain capability required"}
    end
  end

  defp config, do: Ash.get!(Configuration, "coordinator", not_found_error?: false)
  defp configuration_public(nil), do: %{"mode" => "off", "coordinator_id" => nil, "revision" => 0}
  defp configuration_public(row), do: row |> Ops.public() |> Map.delete("id")

  # New-source admission snapshots configuration before Message insertion and
  # holds it through commit. A concurrent mode/revision change cannot strand a
  # source between insertion and capture. Old-message replay has no such permit.
  def prepare_capture do
    unless Repo.in_transaction?(),
      do: Ops.reject("conflict", "Triage capture requires the source transaction")

    Repo.statement!("SELECT pg_advisory_xact_lock_shared($1)", [@lock])
    config()
  end

  def capture_new_message(message, actor, metadata, configuration),
    do: capture_message(message, actor, metadata, {:new_source, configuration})

  # Canonical Message identity owns serialization. Capture never reclassifies a
  # retained row and never runs outside the caller's source transaction.
  def capture_message(message, actor, metadata \\ nil),
    do: capture_message(message, actor, metadata, :replay)

  defp capture_message(message, actor, metadata, admission) do
    unless Repo.in_transaction?(),
      do: Ops.reject("conflict", "Triage capture requires the source transaction")

    unless is_nil(metadata) or Metadata.valid?(metadata),
      do: Ops.reject("invalid_input", "Invalid triage metadata")

    Repo.statement!("SELECT id FROM messages WHERE id=$1 FOR UPDATE", [message.id])
    canonical = Ops.fetch!(Message, message.id, "Message not found")
    prior = Ash.get!(Record, canonical.id, not_found_error?: false)

    cond do
      prior && prior.metadata != metadata ->
        Ops.reject("conflict", "Triage identity already has different metadata")

      prior ->
        prior

      canonical.kind != "note" ->
        if metadata,
          do: Ops.reject("invalid_input", "Triage metadata is only valid for notes"),
          else: nil

      true ->
        {configuration, new_source?} =
          case admission do
            {:new_source, configuration} -> {configuration, true}
            :replay -> {prepare_capture(), false}
          end

        if eligible?(canonical, configuration, new_source?),
          do: capture(canonical, actor, metadata, configuration),
          else: nil
    end
  end

  defp eligible?(_, nil, _), do: false

  defp eligible?(message, configuration, new_source?) do
    configuration.mode == "shadow" and message.recipient_id == configuration.coordinator_id and
      (new_source? or DateTime.compare(message.created_at, configuration.updated_at) != :lt) and
      case Ash.get!(Agent, configuration.coordinator_id, not_found_error?: false) do
        %{retired_at: nil} -> true
        _ -> false
      end
  end

  defp capture(message, actor, metadata, configuration) do
    {verification, issue} = source_evidence(message, metadata)
    classification = Metadata.classification(metadata)
    {state, reason} = disposition(classification, issue)
    stamp = Ops.now()
    internal = Map.put(actor, :triage_internal, true)

    row =
      Ops.create(
        Record,
        :record,
        %{
          message_id: message.id,
          message_created_at: message.created_at,
          recipient_id: message.recipient_id,
          metadata: metadata,
          classification: classification,
          capture_mode: "shadow",
          configuration_revision: configuration.revision,
          policy_version: 1,
          provenance: %{
            "agent" => message.sender_id,
            "model" => message.model,
            "harness" => message.harness,
            "authentication" => Map.get(actor, :triage_authentication, "unverified_attribution"),
            "source_authority" => "unverified"
          },
          source_verification: verification,
          created_at: stamp
        },
        internal
      )

    Ops.create(
      Disposition,
      :record,
      %{
        id: Ecto.UUID.generate(),
        message_id: message.id,
        sequence: 1,
        state: state,
        reason_code: reason,
        created_at: stamp
      },
      internal
    )

    row
  end

  defp disposition("unclassified", _), do: {"blocked", "metadata_missing"}
  defp disposition(_, issue) when not is_nil(issue), do: {"blocked", issue}

  defp disposition(classification, _) when classification in ~w(captain_addressed needs_judgment),
    do: {"escalation_pending", "transport_unavailable"}

  defp disposition("status", _), do: {"recorded", "informational_only"}

  defp disposition(classification, _) when classification in ~w(ci conflict),
    do: {"blocked", "untrusted_source"}

  defp disposition("next_work", _), do: {"blocked", "route_unavailable"}

  defp source_evidence(_, nil), do: {"unclassified", nil}

  defp source_evidence(message, %{"category" => "status", "source" => nil}) do
    if is_nil(message.task_id), do: {"not_applicable", nil}, else: {"missing", "source_required"}
  end

  defp source_evidence(_, %{"attention" => "captain", "source" => nil}),
    do: {"not_applicable", nil}

  defp source_evidence(_, %{"category" => "next_work", "source" => nil}),
    do: {"missing", "assignment_required"}

  defp source_evidence(_, %{"category" => "needs_judgment", "source" => nil}),
    do: {"not_applicable", nil}

  defp source_evidence(message, %{"source" => %{"kind" => "task_status"} = source}) do
    %{rows: rows} =
      Repo.statement!("SELECT task_id,new_revision FROM task_events WHERE id=$1", [
        source["task_event_id"]
      ])

    case rows do
      [[task, revision]] when task == message.task_id ->
        if task == source["task_id"] and revision == source["task_revision"],
          do: {"informational_reference", nil},
          else: {"mismatch", "source_mismatch"}

      [] ->
        {"unavailable", "source_unavailable"}

      _ ->
        {"mismatch", "source_mismatch"}
    end
  end

  defp source_evidence(message, %{
         "category" => category,
         "source" => %{"kind" => "cooperation_event"} = source
       }) do
    %{rows: rows} =
      Repo.statement!(
        "SELECT e.task_id,e.source_key,e.kind,e.repo,t.repo FROM cooperation_events e LEFT JOIN tasks t ON t.id=e.task_id WHERE e.id=$1::text::uuid",
        [source["event_id"]]
      )

    case rows do
      [[task, key, kind, repo, task_repo]] when not is_nil(task) and task == message.task_id ->
        kinds =
          if category == "ci", do: ~w(ci_failure ci_reminder ci_digest), else: ~w(pr_conflict)

        if key == source["source_key"] and kind in kinds and
             repo == Agentboard.SeatScope.canonical_repo(task_repo),
           do: {"unverified_claim", nil},
           else: {"mismatch", "source_mismatch"}

      [] ->
        {"unavailable", "source_unavailable"}

      _ ->
        {"mismatch", "source_mismatch"}
    end
  end

  defp source_evidence(message, %{"source" => %{"kind" => "task_assignment"} = source}) do
    %{rows: rows} =
      Repo.statement!(
        "SELECT t.id,t.assignee_id,t.revision FROM tasks t WHERE t.id=$1 AND EXISTS (SELECT 1 FROM task_events e WHERE e.task_id=t.id AND e.new_revision=$2 AND e.kind='assign' AND e.data->'after'->>'assignee_id'=$3)",
        [source["task_id"], source["assignment_revision"], message.sender_id]
      )

    case rows do
      [[task, sender, revision]] when task == message.task_id and sender == message.sender_id ->
        if revision == source["assignment_revision"],
          do: {"unverified_claim", nil},
          else: {"mismatch", "source_mismatch"}

      [] ->
        {"unavailable", "source_unavailable"}

      _ ->
        {"mismatch", "source_mismatch"}
    end
  end

  defp source_evidence(message, %{"source" => %{"kind" => "decision_request"} = source}) do
    %{rows: rows} =
      Repo.statement!("SELECT task_id FROM decision_requests WHERE id=$1::text::uuid", [
        source["request_id"]
      ])

    case rows do
      [[task]] when task == message.task_id -> {"context_reference", nil}
      [] -> {"unavailable", "source_unavailable"}
      _ -> {"mismatch", "source_mismatch"}
    end
  end

  def for_messages([]), do: %{}

  def for_messages(ids) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT r.message_id, to_jsonb(r) || jsonb_build_object('state',d.state,'reason_code',d.reason_code,
          'task_id',m.task_id,'repo',t.repo,'currentness','not_evaluated',
          'delivery',jsonb_build_object('state','not_attempted'),
          'handling',jsonb_build_object('state','not_inferred'))
        FROM coordinator_inbox_triage r JOIN messages m ON m.id=r.message_id
        LEFT JOIN tasks t ON t.id=m.task_id
        JOIN LATERAL (SELECT state,reason_code FROM coordinator_triage_dispositions
          WHERE message_id=r.message_id ORDER BY sequence DESC LIMIT 1) d ON true
        WHERE r.message_id=ANY($1::bigint[])
        """,
        [ids]
      )

    Map.new(rows, fn [id, value] -> {id, value} end)
  end

  def show(id) do
    Ops.transaction(fn ->
      triage = for_messages([id])[id]

      triage =
        if triage do
          %{rows: rows} =
            Repo.statement!(
              "SELECT to_jsonb(d) FROM coordinator_triage_dispositions d WHERE message_id=$1 ORDER BY sequence",
              [id]
            )

          Map.put(triage, "history", Enum.map(rows, &hd/1))
        end

      %{"triage" => triage}
    end)
  end
end
